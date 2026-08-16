//! Safe project file access for the editor interaction layer.
//!
//! Paths are project-relative and limited to author-owned Boris roots. Every
//! directory component is opened without following symlinks. Saves compare an
//! opaque fingerprint derived from mtime, size, and content hash, then publish
//! through a same-directory atomic file after fsync.

const std = @import("std");
const Io = std.Io;

pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_files = 50_000;
pub const Fingerprint = [64]u8;
const save_temp_prefix = ".boris-editor-save-";
const save_temp_suffix = ".tmp";

pub const Buffer = struct {
    content: []u8,
    fingerprint: Fingerprint,
    read_only: bool,

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
        self.* = undefined;
    }
};

pub const Entry = struct {
    path: []u8,
};

pub const FileList = struct {
    entries: []Entry,

    pub fn deinit(self: *FileList, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| allocator.free(entry.path);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const SaveOutcome = union(enum) {
    saved: Buffer,
    conflict: Buffer,
    deleted,

    pub fn deinit(self: *SaveOutcome, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .saved => |*buffer| buffer.deinit(allocator),
            .conflict => |*buffer| buffer.deinit(allocator),
            .deleted => {},
        }
        self.* = undefined;
    }
};

pub const SaveHook = enum {
    none,
    fail_after_partial_write,
    fail_before_replace,
};

const PathParts = struct {
    parent: []const u8,
    basename: []const u8,
};

const Parent = struct {
    dir: Io.Dir,
    owned: bool,

    fn close(self: Parent, io: Io) void {
        if (self.owned) self.dir.close(io);
    }
};

pub fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096) return error.InvalidPath;
    if (path[0] == '/' or std.fs.path.isAbsolute(path)) return error.InvalidPath;
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return error.InvalidPath;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidPath;

    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) {
            return error.InvalidPath;
        }
        if (isSaveTempName(segment)) return error.InvalidPath;
    }

    const allowed = std.mem.eql(u8, path, "boris.json") or
        std.mem.startsWith(u8, path, "content/") or
        std.mem.startsWith(u8, path, "themes/");
    if (!allowed) return error.PathNotAuthorOwned;
}

pub fn validateFingerprint(value: []const u8) !void {
    if (value.len != 64) return error.InvalidFingerprint;
    for (value) |byte| if (!std.ascii.isHex(byte)) return error.InvalidFingerprint;
}

pub fn list(allocator: std.mem.Allocator, io: Io, project_root: []const u8) !FileList {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.path);
        entries.deinit(allocator);
    }

    try appendTree(allocator, io, root, "content", &entries);
    try appendTree(allocator, io, root, "themes", &entries);
    if (openRegular(io, root, "boris.json")) |file| {
        var owned = file;
        owned.close(io);
        try appendEntry(allocator, &entries, "boris.json");
    } else |_| {}

    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    return .{ .entries = try entries.toOwnedSlice(allocator) };
}

pub fn open(allocator: std.mem.Allocator, io: Io, project_root: []const u8, path: []const u8) !Buffer {
    try validatePath(path);
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    const parts = splitPath(path);
    const parent = try openParent(io, root, parts.parent);
    defer parent.close(io);
    return readBuffer(allocator, io, parent.dir, parts.basename);
}

pub fn save(
    allocator: std.mem.Allocator,
    io: Io,
    project_root: []const u8,
    path: []const u8,
    content: []const u8,
    expected_fingerprint: []const u8,
    recreate: bool,
) !SaveOutcome {
    return saveWithHook(allocator, io, project_root, path, content, expected_fingerprint, recreate, .none);
}

pub fn saveWithHook(
    allocator: std.mem.Allocator,
    io: Io,
    project_root: []const u8,
    path: []const u8,
    content: []const u8,
    expected_fingerprint: []const u8,
    recreate: bool,
    hook: SaveHook,
) !SaveOutcome {
    try validatePath(path);
    if (content.len > max_file_bytes) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    try validateFingerprint(expected_fingerprint);

    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    const parts = splitPath(path);
    const parent = try openParent(io, root, parts.parent);
    defer parent.close(io);

    var current = readBuffer(allocator, io, parent.dir, parts.basename) catch |err| switch (err) {
        error.FileNotFound => {
            if (!recreate) return .deleted;
            try atomicWrite(io, parent.dir, parts.basename, content, null, false, hook);
            return .{ .saved = try readBuffer(allocator, io, parent.dir, parts.basename) };
        },
        else => |other| return other,
    };
    if (current.read_only) {
        current.deinit(allocator);
        return error.ReadOnly;
    }
    if (!std.mem.eql(u8, &current.fingerprint, expected_fingerprint)) {
        return .{ .conflict = current };
    }
    const permissions = blk: {
        var file = try openRegular(io, parent.dir, parts.basename);
        defer file.close(io);
        break :blk (try file.stat(io)).permissions;
    };
    current.deinit(allocator);

    try atomicWrite(io, parent.dir, parts.basename, content, permissions, true, hook);
    return .{ .saved = try readBuffer(allocator, io, parent.dir, parts.basename) };
}

pub fn create(
    allocator: std.mem.Allocator,
    io: Io,
    project_root: []const u8,
    path: []const u8,
    content: []const u8,
) !Buffer {
    try validatePath(path);
    if (content.len > max_file_bytes) return error.FileTooLarge;
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    const parts = splitPath(path);
    const parent = try openParent(io, root, parts.parent);
    defer parent.close(io);

    if (parent.dir.access(io, parts.basename, .{ .follow_symlinks = false })) |_| {
        return error.PathAlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    }
    try atomicWrite(io, parent.dir, parts.basename, content, null, false, .none);
    return readBuffer(allocator, io, parent.dir, parts.basename);
}

pub fn rename(io: Io, project_root: []const u8, source_path: []const u8, destination_path: []const u8) !void {
    try validatePath(source_path);
    try validatePath(destination_path);
    if (std.mem.eql(u8, source_path, destination_path)) return;
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);

    const source_parts = splitPath(source_path);
    const destination_parts = splitPath(destination_path);
    const source_parent = try openParent(io, root, source_parts.parent);
    defer source_parent.close(io);
    const destination_parent = try openParent(io, root, destination_parts.parent);
    defer destination_parent.close(io);

    var source_file = try openRegular(io, source_parent.dir, source_parts.basename);
    source_file.close(io);
    try source_parent.dir.renamePreserve(source_parts.basename, destination_parent.dir, destination_parts.basename, io);
}

pub fn delete(io: Io, project_root: []const u8, path: []const u8, confirmed: bool) !void {
    if (!confirmed) return error.ConfirmationRequired;
    try validatePath(path);
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .follow_symlinks = false });
    defer root.close(io);
    const parts = splitPath(path);
    const parent = try openParent(io, root, parts.parent);
    defer parent.close(io);
    var file = try openRegular(io, parent.dir, parts.basename);
    file.close(io);
    try parent.dir.deleteFile(io, parts.basename);
}

fn appendTree(allocator: std.mem.Allocator, io: Io, root: Io.Dir, name: []const u8, entries: *std.ArrayList(Entry)) !void {
    var dir = root.openDir(io, name, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    defer dir.close(io);
    try walk(allocator, io, dir, name, entries);
}

fn walk(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, prefix: []const u8, entries: *std.ArrayList(Entry)) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (isSaveTempName(entry.name)) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(full);
        if (!std.unicode.utf8ValidateSlice(full)) continue;
        switch (entry.kind) {
            .file => try appendEntry(allocator, entries, full),
            .directory => {
                var child = dir.openDir(io, entry.name, .{ .iterate = true, .follow_symlinks = false }) catch continue;
                defer child.close(io);
                try walk(allocator, io, child, full, entries);
            },
            else => {},
        }
    }
}

fn appendEntry(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), path: []const u8) !void {
    if (entries.items.len >= max_files) return error.TooManyFiles;
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    try entries.append(allocator, .{ .path = owned_path });
}

fn splitPath(path: []const u8) PathParts {
    const separator = std.mem.lastIndexOfScalar(u8, path, '/');
    return if (separator) |index|
        .{ .parent = path[0..index], .basename = path[index + 1 ..] }
    else
        .{ .parent = "", .basename = path };
}

fn openParent(io: Io, root: Io.Dir, parent_path: []const u8) !Parent {
    if (parent_path.len == 0) return .{ .dir = root, .owned = false };
    var current = root;
    var current_owned = false;
    errdefer if (current_owned) current.close(io);
    var segments = std.mem.splitScalar(u8, parent_path, '/');
    while (segments.next()) |segment| {
        const next = try current.openDir(io, segment, .{ .follow_symlinks = false });
        if (current_owned) current.close(io);
        current = next;
        current_owned = true;
    }
    return .{ .dir = current, .owned = current_owned };
}

fn openRegular(io: Io, dir: Io.Dir, basename: []const u8) !Io.File {
    var file = try dir.openFile(io, basename, .{
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    });
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.NotRegularFile;
    return file;
}

fn readBuffer(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, basename: []const u8) !Buffer {
    var file = try openRegular(io, dir, basename);
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.size > max_file_bytes) return error.FileTooLarge;
    var reader = file.reader(io, &.{});
    const content = try reader.interface.allocRemaining(allocator, .limited(max_file_bytes));
    errdefer allocator.free(content);
    if (!std.unicode.utf8ValidateSlice(content)) return error.InvalidUtf8;
    return .{
        .content = content,
        .fingerprint = fingerprint(stat, content),
        .read_only = stat.permissions.readOnly(),
    };
}

fn fingerprint(stat: Io.File.Stat, content: []const u8) Fingerprint {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var metadata: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&metadata, "{d}:{d}:", .{ stat.size, stat.mtime.nanoseconds }) catch unreachable;
    hasher.update(text);
    var content_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(content, &content_digest, .{});
    hasher.update(&content_digest);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn atomicWrite(
    io: Io,
    parent: Io.Dir,
    basename: []const u8,
    content: []const u8,
    permissions: ?Io.File.Permissions,
    replace: bool,
    hook: SaveHook,
) !void {
    var temp_name_buffer: [save_temp_prefix.len + 32 + save_temp_suffix.len]u8 = undefined;
    var temp_file: Io.File = undefined;
    var temp_name: []const u8 = undefined;
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        var random: [16]u8 = undefined;
        try io.randomSecure(&random);
        temp_name = std.fmt.bufPrint(&temp_name_buffer, "{s}{x}{s}", .{ save_temp_prefix, random, save_temp_suffix }) catch unreachable;
        temp_file = parent.createFile(io, temp_name, .{
            .exclusive = true,
            .permissions = permissions orelse .default_file,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |other| return other,
        };
        break;
    } else return error.TempNameExhausted;

    var file_open = true;
    defer if (file_open) temp_file.close(io);
    var temp_exists = true;
    defer if (temp_exists) parent.deleteFile(io, temp_name) catch {};
    var buffer: [16 * 1024]u8 = undefined;
    var writer = temp_file.writer(io, &buffer);

    if (hook == .fail_after_partial_write) {
        const partial_len = if (content.len == 0) 0 else @max(@as(usize, 1), content.len / 2);
        try writer.interface.writeAll(content[0..partial_len]);
        try writer.flush();
        try temp_file.sync(io);
        return error.InjectedSaveFailure;
    }

    try writer.interface.writeAll(content);
    try writer.flush();
    try temp_file.sync(io);
    if (hook == .fail_before_replace) return error.InjectedSaveFailure;
    temp_file.close(io);
    file_open = false;
    if (replace)
        try parent.rename(temp_name, parent, basename, io)
    else
        try parent.renamePreserve(temp_name, parent, basename, io);
    temp_exists = false;
}

fn isSaveTempName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, save_temp_prefix) or !std.mem.endsWith(u8, name, save_temp_suffix)) return false;
    const hex = name[save_temp_prefix.len .. name.len - save_temp_suffix.len];
    if (hex.len != 32) return false;
    for (hex) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn createTestProject() !std.testing.TmpDir {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    errdefer temp.cleanup();
    try temp.dir.createDirPath(io, "content/guides");
    try temp.dir.createDirPath(io, "themes/boris/layouts");
    try temp.dir.writeFile(io, .{ .sub_path = "content/index.md", .data = "# Original\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "themes/boris/layouts/main.html", .data = "{{content}}" });
    try temp.dir.writeFile(io, .{ .sub_path = "boris.json", .data = "{}\n" });
    return temp;
}

fn testProjectPath(temp: *std.testing.TmpDir, allocator: std.mem.Allocator) ![:0]u8 {
    return temp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
}

test "paths stay inside author-owned project roots" {
    try validatePath("content/guides/page.md");
    try validatePath("themes/boris/layouts/main.html");
    try validatePath("boris.json");
    try std.testing.expectError(error.InvalidPath, validatePath("../secret"));
    try std.testing.expectError(error.InvalidPath, validatePath("content/../secret"));
    try std.testing.expectError(error.PathNotAuthorOwned, validatePath("dist/index.html"));
    try std.testing.expectError(error.PathNotAuthorOwned, validatePath(".boris/graph.json"));
    try validateFingerprint("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try std.testing.expectError(error.InvalidFingerprint, validateFingerprint("not-a-fingerprint"));
}

test "file list is deterministic and excludes outputs and symlinks" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "dist");
    try temp.dir.writeFile(io, .{ .sub_path = "dist/index.html", .data = "generated" });
    try temp.dir.writeFile(io, .{ .sub_path = "content/.boris-editor-save-0123456789abcdef0123456789abcdef.tmp", .data = "partial" });
    temp.dir.symLink(io, "content/index.md", "content/link.md", .{}) catch {};
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var files = try list(allocator, io, root);
    defer files.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), files.entries.len);
    try std.testing.expectEqualStrings("boris.json", files.entries[0].path);
    try std.testing.expectEqualStrings("content/index.md", files.entries[1].path);
    try std.testing.expectEqualStrings("themes/boris/layouts/main.html", files.entries[2].path);
    try std.testing.expectError(error.InvalidPath, validatePath("content/.boris-editor-save-0123456789abcdef0123456789abcdef.tmp"));
}

test "external edit conflicts and preserves the external bytes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var opened = try open(allocator, io, root, "content/index.md");
    defer opened.deinit(allocator);
    try temp.dir.writeFile(io, .{ .sub_path = "content/index.md", .data = "# External\n" });

    var result = try save(allocator, io, root, "content/index.md", "# Mine\n", &opened.fingerprint, false);
    defer result.deinit(allocator);
    try std.testing.expect(result == .conflict);
    try std.testing.expectEqualStrings("# External\n", result.conflict.content);
}

test "failed and partial saves leave the original intact" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var opened = try open(allocator, io, root, "content/index.md");
    defer opened.deinit(allocator);

    for ([_]SaveHook{ .fail_after_partial_write, .fail_before_replace }) |hook| {
        try std.testing.expectError(error.InjectedSaveFailure, saveWithHook(
            allocator,
            io,
            root,
            "content/index.md",
            "# Replacement\n",
            &opened.fingerprint,
            false,
            hook,
        ));
        var after = try open(allocator, io, root, "content/index.md");
        defer after.deinit(allocator);
        try std.testing.expectEqualStrings("# Original\n", after.content);
    }
}

test "rename collisions never clobber" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "content/existing.md", .data = "keep\n" });
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    try std.testing.expectError(error.PathAlreadyExists, rename(io, root, "content/index.md", "content/existing.md"));
    var existing = try open(allocator, io, root, "content/existing.md");
    defer existing.deinit(allocator);
    try std.testing.expectEqualStrings("keep\n", existing.content);
}

test "deleted-on-disk requires explicit recreation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var opened = try open(allocator, io, root, "content/index.md");
    defer opened.deinit(allocator);
    try temp.dir.deleteFile(io, "content/index.md");
    var deleted = try save(allocator, io, root, "content/index.md", "# Recreated\n", &opened.fingerprint, false);
    defer deleted.deinit(allocator);
    try std.testing.expect(deleted == .deleted);
    var recreated = try save(allocator, io, root, "content/index.md", "# Recreated\n", &opened.fingerprint, true);
    defer recreated.deinit(allocator);
    try std.testing.expect(recreated == .saved);
}

test "read-only files fail before replacement" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var file = try temp.dir.openFile(io, "content/index.md", .{});
    const original_permissions = (try file.stat(io)).permissions;
    file.close(io);
    try temp.dir.setFilePermissions(io, "content/index.md", original_permissions.setReadOnly(true), .{});
    defer temp.dir.setFilePermissions(io, "content/index.md", original_permissions, .{}) catch {};
    var opened = try open(allocator, io, root, "content/index.md");
    defer opened.deinit(allocator);
    try std.testing.expect(opened.read_only);
    try std.testing.expectError(error.ReadOnly, save(allocator, io, root, "content/index.md", "changed", &opened.fingerprint, false));
}

test "create and confirmed delete use no-clobber semantics" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    var created = try create(allocator, io, root, "content/guides/new.md", "# New\n");
    defer created.deinit(allocator);
    try std.testing.expectError(error.PathAlreadyExists, create(allocator, io, root, "content/guides/new.md", "clobber"));
    try std.testing.expectError(error.ConfirmationRequired, delete(io, root, "content/guides/new.md", false));
    try delete(io, root, "content/guides/new.md", true);
    try std.testing.expectError(error.FileNotFound, open(allocator, io, root, "content/guides/new.md"));
}

test "files larger than 8 MiB are refused without writing" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = try createTestProject();
    defer temp.cleanup();
    const root = try testProjectPath(&temp, allocator);
    defer allocator.free(root);
    const huge = try allocator.alloc(u8, max_file_bytes + 1);
    defer allocator.free(huge);
    @memset(huge, 'a');
    try std.testing.expectError(error.FileTooLarge, create(allocator, io, root, "content/huge.md", huge));
    try std.testing.expectError(error.FileNotFound, open(allocator, io, root, "content/huge.md"));
}
