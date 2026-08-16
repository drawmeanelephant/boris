//! Crash-recovery snapshots for dirty editor buffers. Snapshot files are
//! disposable derived state under the editor cache root, never project truth.

const std = @import("std");
const Io = std.Io;
const file_api = @import("file_api.zig");

pub const Snapshot = struct {
    path: []u8,
    content: []u8,
    fingerprint: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.content);
        allocator.free(self.fingerprint);
        self.* = undefined;
    }
};

pub const SnapshotList = struct {
    snapshots: []Snapshot,
    skipped: usize = 0,

    pub fn deinit(self: *SnapshotList, allocator: std.mem.Allocator) void {
        for (self.snapshots) |*snapshot| snapshot.deinit(allocator);
        allocator.free(self.snapshots);
        self.* = undefined;
    }
};

const DiskSnapshot = struct {
    format: []const u8,
    schema_version: u32,
    path: []const u8,
    content: []const u8,
    fingerprint: []const u8,
};

pub fn save(
    allocator: std.mem.Allocator,
    io: Io,
    state_root: []const u8,
    path: []const u8,
    content: []const u8,
    fingerprint: []const u8,
) !void {
    try file_api.validatePath(path);
    try file_api.validateFingerprint(fingerprint);
    if (content.len > file_api.max_file_bytes) return error.SnapshotTooLarge;
    if (!std.unicode.utf8ValidateSlice(path) or !std.unicode.utf8ValidateSlice(content)) return error.InvalidSnapshot;
    const recovery_path = try std.fs.path.join(allocator, &.{ state_root, "recovery" });
    defer allocator.free(recovery_path);
    try Io.Dir.cwd().createDirPath(io, recovery_path);
    var dir = try Io.Dir.cwd().openDir(io, recovery_path, .{ .follow_symlinks = false });
    defer dir.close(io);

    const name = snapshotName(path);
    const document = .{
        .format = "boris-editor-recovery",
        .schema_version = @as(u32, 1),
        .path = path,
        .content = content,
        .fingerprint = fingerprint,
    };
    const bytes = try std.json.Stringify.valueAlloc(allocator, document, .{});
    defer allocator.free(bytes);
    var atomic = try dir.createFileAtomic(io, &name, .{ .replace = true });
    defer atomic.deinit(io);
    var write_buffer: [16 * 1024]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn clear(io: Io, state_root: []const u8, path: []const u8) !void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const recovery_path = try std.fmt.bufPrint(&path_buffer, "{s}{c}recovery", .{ state_root, std.fs.path.sep });
    var dir = Io.Dir.cwd().openDir(io, recovery_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    defer dir.close(io);
    const name = snapshotName(path);
    dir.deleteFile(io, &name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

pub fn loadAll(allocator: std.mem.Allocator, io: Io, state_root: []const u8) !SnapshotList {
    const recovery_path = try std.fs.path.join(allocator, &.{ state_root, "recovery" });
    defer allocator.free(recovery_path);
    var dir = Io.Dir.cwd().openDir(io, recovery_path, .{ .iterate = true, .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .{ .snapshots = try allocator.alloc(Snapshot, 0), .skipped = 0 },
        else => |other| return other,
    };
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, names.items, {}, struct {
        fn less(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);

    var snapshots: std.ArrayList(Snapshot) = .empty;
    errdefer {
        for (snapshots.items) |*snapshot| snapshot.deinit(allocator);
        snapshots.deinit(allocator);
    }
    var skipped: usize = 0;
    for (names.items) |name| {
        const bytes = try dir.readFileAlloc(io, name, allocator, .limited(10 * 1024 * 1024));
        defer allocator.free(bytes);
        var parsed = std.json.parseFromSlice(DiskSnapshot, allocator, bytes, .{}) catch {
            skipped += 1;
            continue;
        };
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.format, "boris-editor-recovery") or parsed.value.schema_version != 1) {
            skipped += 1;
            continue;
        }
        file_api.validatePath(parsed.value.path) catch {
            skipped += 1;
            continue;
        };
        file_api.validateFingerprint(parsed.value.fingerprint) catch {
            skipped += 1;
            continue;
        };
        if (parsed.value.content.len > file_api.max_file_bytes or !std.unicode.utf8ValidateSlice(parsed.value.content)) {
            skipped += 1;
            continue;
        }
        const owned_path = try allocator.dupe(u8, parsed.value.path);
        errdefer allocator.free(owned_path);
        const owned_content = try allocator.dupe(u8, parsed.value.content);
        errdefer allocator.free(owned_content);
        const owned_fingerprint = try allocator.dupe(u8, parsed.value.fingerprint);
        errdefer allocator.free(owned_fingerprint);
        try snapshots.append(allocator, .{
            .path = owned_path,
            .content = owned_content,
            .fingerprint = owned_fingerprint,
        });
    }
    std.mem.sort(Snapshot, snapshots.items, {}, struct {
        fn less(_: void, left: Snapshot, right: Snapshot) bool {
            return std.mem.order(u8, left.path, right.path) == .lt;
        }
    }.less);
    return .{ .snapshots = try snapshots.toOwnedSlice(allocator), .skipped = skipped };
}

fn snapshotName(path: []const u8) [69]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    var name: [69]u8 = undefined;
    @memcpy(name[0..64], &hex);
    @memcpy(name[64..], ".json");
    return name;
}

test "dirty buffers survive a new recovery-store instance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try save(allocator, io, root, "content/index.md", "unsaved\n", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var restarted = try loadAll(allocator, io, root);
    defer restarted.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), restarted.snapshots.len);
    try std.testing.expectEqualStrings("content/index.md", restarted.snapshots[0].path);
    try std.testing.expectEqualStrings("unsaved\n", restarted.snapshots[0].content);
    try clear(io, root, "content/index.md");
    var empty = try loadAll(allocator, io, root);
    defer empty.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.snapshots.len);
}

test "one corrupt snapshot does not drop the valid ones" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try save(allocator, io, root, "content/index.md", "keep\n", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    var recovery_dir = try temp.dir.openDir(io, "recovery", .{});
    defer recovery_dir.close(io);
    try recovery_dir.writeFile(io, .{ .sub_path = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff.json", .data = "{not-json" });

    var loaded = try loadAll(allocator, io, root);
    defer loaded.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), loaded.snapshots.len);
    try std.testing.expectEqual(@as(usize, 1), loaded.skipped);
    try std.testing.expectEqualStrings("content/index.md", loaded.snapshots[0].path);
    try std.testing.expectEqualStrings("keep\n", loaded.snapshots[0].content);
}
