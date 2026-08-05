//! Output ownership and atomic replacement for boris-content-audit.
//!
//! Safety rules implemented here:
//!   - refuse replacing a non-empty unmarked output directory;
//!   - refuse unmarked or stale stage directories;
//!   - stage all output in a sibling temporary directory;
//!   - atomically rename the stage into place (POSIX directory rename);
//!   - leave the previous valid report intact after any failure;
//!   - clean temporary stages after failure;
//!   - never write into the audited source tree (the CLI layer refuses
//!     source/output overlap before this module runs).

const std = @import("std");
const util = @import("util.zig");

fn pathExists(io: std.Io, root: std.Io.Dir, rel: []const u8) bool {
    _ = root.statFile(io, rel, .{}) catch return false;
    return true;
}

fn dirIsEmpty(io: std.Io, dir: std.Io.Dir) bool {
    var it = dir.iterate();
    return (it.next(io) catch return false) == null;
}

/// Validate the final output path: refuse unmarked non-empty directories.
pub fn prepareOwnedStage(io: std.Io, final_path: []const u8, stage_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, final_path, .{})) |final_dir| {
        defer final_dir.close(io);
        if (!dirIsEmpty(io, final_dir) and !pathExists(io, final_dir, util.output_owner_marker)) {
            return error.RefuseUnownedOutput;
        }
    } else |_| {}
    if (cwd.openDir(io, stage_path, .{})) |stage_dir| {
        defer stage_dir.close(io);
        if (!dirIsEmpty(io, stage_dir) and !pathExists(io, stage_dir, util.output_owner_marker)) {
            return error.RefuseUnownedStage;
        }
        cwd.deleteTree(io, stage_path) catch return error.StageCleanupFailed;
    } else |_| {}
    try cwd.createDirPath(io, stage_path);
}

/// Atomically publish the stage as the final output. On failure the previous
/// output (if any) is restored and the stage is removed.
pub fn publishOwnedStage(io: std.Io, final_path: []const u8, stage_path: []const u8, backup_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, backup_path) catch {};
    var moved_previous = false;
    if (cwd.openDir(io, final_path, .{})) |final_dir| {
        final_dir.close(io);
        try cwd.rename(final_path, cwd, backup_path, io);
        moved_previous = true;
    } else |_| {}
    cwd.rename(stage_path, cwd, final_path, io) catch |err| {
        if (moved_previous) cwd.rename(backup_path, cwd, final_path, io) catch {};
        cwd.deleteTree(io, stage_path) catch {};
        return err;
    };
    if (moved_previous) cwd.deleteTree(io, backup_path) catch {};
}

/// Remove a leftover stage/backup without touching anything else.
pub fn cleanupPath(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

fn ensureParent(io: std.Io, root: std.Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

pub fn writeBytes(io: std.Io, root: std.Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

pub fn readFileAlloc(io: std.Io, dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

/// Hex SHA-256 of a file's contents. Used by tests to prove the audited
/// source tree is never mutated (before/after comparison).
pub fn hashFile(io: std.Io, gpa: std.mem.Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    const bytes = try readFileAlloc(io, dir, path, gpa);
    return util.sha256Hex(gpa, bytes);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn ta() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "unmarked non-empty output refused" {
    const io = std.testing.io;
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const final_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    const stage_path = try std.fmt.allocPrint(a, "{s}.boris-content-audit-stage", .{final_path});
    try std.Io.Dir.cwd().createDirPath(io, final_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/precious.txt", .{final_path}), .data = "do not clobber" });
    try std.testing.expectError(error.RefuseUnownedOutput, prepareOwnedStage(io, final_path, stage_path));
}

test "marked output replaced atomically" {
    const io = std.testing.io;
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const final_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    const stage_path = try std.fmt.allocPrint(a, "{s}.boris-content-audit-stage", .{final_path});
    const backup_path = try std.fmt.allocPrint(a, "{s}.boris-content-audit-backup", .{final_path});
    // First publish.
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), "owned\n");
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{}");
    try publishOwnedStage(io, final_path, stage_path, backup_path);
    try std.testing.expect((std.Io.Dir.cwd().openDir(io, final_path, .{}) catch null) != null);
    // Second publish over the marked output.
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), "owned\n");
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{\"v\":2}");
    try publishOwnedStage(io, final_path, stage_path, backup_path);
    const data = try readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{final_path}), a);
    try std.testing.expectEqualStrings("{\"v\":2}", data);
}

test "hashFile deterministic" {
    const io = std.testing.io;
    var arena = ta();
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch {};
        tmp.parent_dir.close(io);
    }
    const p = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/a.md", .{tmp.sub_path});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = "hello" });
    const h1 = try hashFile(io, a, std.Io.Dir.cwd(), p);
    const h2 = try hashFile(io, a, std.Io.Dir.cwd(), p);
    try std.testing.expectEqualStrings(h1, h2);
}
