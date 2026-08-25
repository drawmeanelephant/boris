//! Owned, staged publication for migration-lab outputs.
//!
//! Migration inputs are often irreplaceable exports.  Every writer uses this
//! module so it validates source/output separation before creating anything,
//! writes a complete replacement into a sibling stage, and only replaces a
//! previous lab-owned result after the stage is complete.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

pub const marker_name = ".boris-migration-lab-output";

pub const Error = error{
    InputOutputOverlap,
    InputSymlink,
    OutputSymlink,
    OutputNotOwned,
    StageNotOwned,
    BackupNotOwned,
    OutputNotDirectory,
    StageCleanupFailed,
    BackupCleanupFailed,
    PublishRollbackFailed,
};

pub const Publication = struct {
    final_path: []const u8,
    stage_path: []u8,
    backup_path: []u8,
    marker: []u8,
    active: bool = true,

    /// Creates an owned sibling stage after proving that no input can be the
    /// output root, an ancestor, or a descendant of it.  `inputs` may contain
    /// both files (such as WXR/ledger) and directories.
    pub fn begin(
        io: Io,
        allocator: std.mem.Allocator,
        final_path: []const u8,
        inputs: []const []const u8,
        owner: []const u8,
    ) !Publication {
        try validateRoots(io, allocator, final_path, inputs);

        var publication = Publication{
            .final_path = final_path,
            .stage_path = try std.fmt.allocPrint(allocator, "{s}.boris-migration-lab-stage", .{final_path}),
            .backup_path = try std.fmt.allocPrint(allocator, "{s}.boris-migration-lab-prev", .{final_path}),
            .marker = try std.fmt.allocPrint(allocator, "format=boris-migration-lab-output\nowner={s}\nschema_version=1\n", .{owner}),
        };
        errdefer publication.deinit(allocator);
        errdefer publication.abandon(io, allocator);

        try rejectSymlinkAlongPath(io, allocator, publication.stage_path, error.OutputSymlink);
        try rejectSymlinkAlongPath(io, allocator, publication.backup_path, error.OutputSymlink);
        try publication.prepare(io, allocator);
        return publication;
    }

    pub fn deinit(self: *Publication, allocator: std.mem.Allocator) void {
        allocator.free(self.stage_path);
        allocator.free(self.backup_path);
        allocator.free(self.marker);
        self.* = undefined;
    }

    /// Removes a still-active stage only when it carries this exact owner
    /// marker. This leaves the previous final output untouched on conversion
    /// failures.
    pub fn abandon(self: *Publication, io: Io, allocator: std.mem.Allocator) void {
        if (!self.active) return;
        const cwd = Io.Dir.cwd();
        if (isOwnedDirectory(io, allocator, cwd, self.stage_path, self.marker)) {
            cwd.deleteTree(io, self.stage_path) catch {};
        }
        self.active = false;
    }

    /// Atomically moves the complete stage into place on the same filesystem.
    /// A previous result is moved aside and restored if the stage rename fails.
    pub fn commit(self: *Publication, io: Io, allocator: std.mem.Allocator) !void {
        const cwd = Io.Dir.cwd();
        try deleteOwnedIfPresent(io, allocator, cwd, self.backup_path, self.marker, error.BackupNotOwned);

        var moved_previous = false;
        if (directoryExists(io, cwd, self.final_path)) {
            try cwd.rename(self.final_path, cwd, self.backup_path, io);
            moved_previous = true;
        } else if (pathExists(io, cwd, self.final_path)) {
            return error.OutputNotDirectory;
        }

        cwd.rename(self.stage_path, cwd, self.final_path, io) catch |err| {
            if (moved_previous) {
                cwd.rename(self.backup_path, cwd, self.final_path, io) catch return error.PublishRollbackFailed;
            }
            return err;
        };
        self.active = false;

        if (moved_previous) {
            cwd.deleteTree(io, self.backup_path) catch {
                // The new tree is already installed, but a cleanup failure must
                // not be reported as a successful replacement with a stale
                // previous tree left behind. Roll back while both trees are
                // still owned and on the same filesystem.
                cwd.rename(self.final_path, cwd, self.stage_path, io) catch return error.BackupCleanupFailed;
                cwd.rename(self.backup_path, cwd, self.final_path, io) catch {
                    cwd.rename(self.stage_path, cwd, self.final_path, io) catch return error.PublishRollbackFailed;
                    return error.BackupCleanupFailed;
                };
                self.active = true;
                return error.BackupCleanupFailed;
            };
        }
    }

    fn prepare(self: *Publication, io: Io, allocator: std.mem.Allocator) !void {
        const cwd = Io.Dir.cwd();
        if (directoryExists(io, cwd, self.final_path)) {
            if (!isEmptyOrOwned(io, allocator, cwd, self.final_path, self.marker)) return error.OutputNotOwned;
        } else if (pathExists(io, cwd, self.final_path)) {
            return error.OutputNotDirectory;
        }

        try deleteOwnedIfPresent(io, allocator, cwd, self.stage_path, self.marker, error.StageNotOwned);
        try cwd.createDirPath(io, self.stage_path);
        var stage = try cwd.openDir(io, self.stage_path, .{});
        defer stage.close(io);
        try stage.writeFile(io, .{ .sub_path = marker_name, .data = self.marker });
    }
};

pub fn validateRoots(
    io: Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    inputs: []const []const u8,
) !void {
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const output_abs = try resolveNormalized(allocator, cwd_path, output_path);
    defer allocator.free(output_abs);

    try rejectSymlinkAlongPath(io, allocator, output_path, error.OutputSymlink);
    for (inputs) |input| {
        const input_abs = try resolveNormalized(allocator, cwd_path, input);
        defer allocator.free(input_abs);
        if (pathsNestOrEqual(output_abs, input_abs)) return error.InputOutputOverlap;
        try rejectSymlinkAlongPath(io, allocator, input, error.InputSymlink);
    }
}

fn resolveNormalized(allocator: std.mem.Allocator, cwd_path: []const u8, path: []const u8) ![]u8 {
    const resolved = try std.fs.path.resolve(allocator, &.{ cwd_path, path });
    for (resolved) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return stripTrailingSlash(resolved, allocator);
}

fn stripTrailingSlash(path: []u8, allocator: std.mem.Allocator) ![]u8 {
    if (path.len <= 1 or path[path.len - 1] != '/') return path;
    const trimmed = try allocator.dupe(u8, path[0 .. path.len - 1]);
    allocator.free(path);
    return trimmed;
}

fn pathsNestOrEqual(a: []const u8, b: []const u8) bool {
    return hasPathPrefix(a, b) or hasPathPrefix(b, a);
}

fn hasPathPrefix(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    const equal = if (builtin.os.tag == .windows or builtin.os.tag == .macos)
        std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix)
    else
        std.mem.eql(u8, path[0..prefix.len], prefix);
    return equal and (path.len == prefix.len or prefix.len == 1 or path[prefix.len] == '/');
}

fn rejectSymlinkAlongPath(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    comptime err: anyerror,
) !void {
    var normalized = try allocator.dupe(u8, path);
    defer allocator.free(normalized);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
    }

    var start: usize = 0;
    while (start < normalized.len) {
        if (normalized[start] == '/') {
            start += 1;
            continue;
        }
        const slash = std.mem.indexOfScalarPos(u8, normalized, start, '/') orelse normalized.len;
        const progressive = normalized[0..slash];
        if (progressive.len > 0 and !std.mem.eql(u8, progressive, ".") and !std.mem.eql(u8, progressive, "..") and
            !(progressive.len == 1 and progressive[0] == '/'))
        {
            if (Io.Dir.cwd().statFile(io, progressive, .{ .follow_symlinks = false })) |stat| {
                if (stat.kind == .sym_link) return err;
            } else |_| {}
        }
        if (slash == normalized.len) break;
        start = slash + 1;
    }
}

fn pathExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch return false;
    return true;
}

fn directoryExists(io: Io, dir: Io.Dir, path: []const u8) bool {
    var opened = dir.openDir(io, path, .{}) catch return false;
    opened.close(io);
    return true;
}

fn directoryIsEmpty(io: Io, dir: Io.Dir) bool {
    var iterator = dir.iterate();
    return (iterator.next(io) catch return false) == null;
}

fn readMarker(
    io: Io,
    allocator: std.mem.Allocator,
    dir: Io.Dir,
) ?[]u8 {
    var file = dir.openFile(io, marker_name, .{}) catch return null;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(4096)) catch null;
}

fn isOwnedDirectory(
    io: Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    path: []const u8,
    marker: []const u8,
) bool {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    const found = readMarker(io, allocator, dir) orelse return false;
    defer allocator.free(found);
    return std.mem.eql(u8, found, marker);
}

fn isEmptyOrOwned(
    io: Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    path: []const u8,
    marker: []const u8,
) bool {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    return directoryIsEmpty(io, dir) or isOwnedDirectory(io, allocator, cwd, path, marker);
}

fn deleteOwnedIfPresent(
    io: Io,
    allocator: std.mem.Allocator,
    cwd: Io.Dir,
    path: []const u8,
    marker: []const u8,
    comptime ownership_error: anyerror,
) !void {
    if (directoryExists(io, cwd, path)) {
        if (!isOwnedDirectory(io, allocator, cwd, path, marker)) return ownership_error;
        cwd.deleteTree(io, path) catch return error.StageCleanupFailed;
    } else if (pathExists(io, cwd, path)) {
        return ownership_error;
    }
}

test "path containment rejects aliases and both nesting directions" {
    try std.testing.expect(pathsNestOrEqual("/work/theme", "/work/theme"));
    try std.testing.expect(pathsNestOrEqual("/work/theme", "/work/theme/out"));
    try std.testing.expect(pathsNestOrEqual("/work/theme/out", "/work/theme"));
    try std.testing.expect(!pathsNestOrEqual("/work/theme", "/work/theme-next"));
}

test "root validation rejects output overlap with directory and file inputs" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/publication-roots", .{tmp.sub_path});
    defer a.free(root);
    const source = try std.fmt.allocPrint(a, "{s}/source", .{root});
    defer a.free(source);
    const nested_out = try std.fmt.allocPrint(a, "{s}/out", .{source});
    defer a.free(nested_out);
    const file_in_out = try std.fmt.allocPrint(a, "{s}/export.xml", .{nested_out});
    defer a.free(file_in_out);

    try std.testing.expectError(error.InputOutputOverlap, validateRoots(io, a, nested_out, &.{source}));
    try std.testing.expectError(error.InputOutputOverlap, validateRoots(io, a, nested_out, &.{file_in_out}));
}

fn writeStageFile(io: Io, publication: *Publication, name: []const u8, bytes: []const u8) !void {
    var stage = try Io.Dir.cwd().openDir(io, publication.stage_path, .{});
    defer stage.close(io);
    try stage.writeFile(io, .{ .sub_path = name, .data = bytes });
}

test "publication refuses an unowned output without touching it" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/publication-unowned", .{tmp.sub_path});
    defer a.free(root);
    const input = try std.fmt.allocPrint(a, "{s}/input", .{root});
    defer a.free(input);
    const out = try std.fmt.allocPrint(a, "{s}/out", .{root});
    defer a.free(out);
    try Io.Dir.cwd().createDirPath(io, input);
    try Io.Dir.cwd().createDirPath(io, out);
    const keep_path = try std.fmt.allocPrint(a, "{s}/KEEP", .{out});
    defer a.free(keep_path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = keep_path, .data = "do not delete" });

    try std.testing.expectError(error.OutputNotOwned, Publication.begin(io, a, out, &.{input}, "test-owner"));
    var out_dir = try Io.Dir.cwd().openDir(io, out, .{});
    defer out_dir.close(io);
    var keep_file = try out_dir.openFile(io, "KEEP", .{});
    defer keep_file.close(io);
    var keep_reader = keep_file.reader(io, &.{});
    const keep = try keep_reader.interface.allocRemaining(a, .limited(4096));
    defer a.free(keep);
    try std.testing.expectEqualStrings("do not delete", keep);
}

test "publication replaces only a complete owned output and abandon preserves the prior result" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/publication-owned", .{tmp.sub_path});
    defer a.free(root);
    const input = try std.fmt.allocPrint(a, "{s}/input", .{root});
    defer a.free(input);
    const out = try std.fmt.allocPrint(a, "{s}/out", .{root});
    defer a.free(out);
    try Io.Dir.cwd().createDirPath(io, input);

    var first = try Publication.begin(io, a, out, &.{input}, "test-owner");
    defer first.deinit(a);
    try writeStageFile(io, &first, "old.txt", "old");
    try first.commit(io, a);

    var replacement = try Publication.begin(io, a, out, &.{input}, "test-owner");
    defer replacement.deinit(a);
    try writeStageFile(io, &replacement, "new.txt", "new");
    replacement.abandon(io, a);

    var live = try Io.Dir.cwd().openDir(io, out, .{});
    defer live.close(io);
    var old = try live.openFile(io, "old.txt", .{});
    defer old.close(io);
    try std.testing.expectError(error.FileNotFound, live.openFile(io, "new.txt", .{}));

    var second = try Publication.begin(io, a, out, &.{input}, "test-owner");
    defer second.deinit(a);
    try writeStageFile(io, &second, "new.txt", "new");
    try second.commit(io, a);

    var replaced = try Io.Dir.cwd().openDir(io, out, .{});
    defer replaced.close(io);
    var new = try replaced.openFile(io, "new.txt", .{});
    defer new.close(io);
    try std.testing.expectError(error.FileNotFound, replaced.openFile(io, "old.txt", .{}));
}
