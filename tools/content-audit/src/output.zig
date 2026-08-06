//! Output ownership and atomic replacement for boris-content-audit.
//!
//! Safety rules implemented here:
//!   - refuse replacing a non-empty unmarked output directory;
//!   - refuse unmarked or stale stage directories;
//!   - validate the ownership marker's **content**, not only its filename;
//!   - refuse deleting an existing backup that is not provably ours;
//!   - stage all output in a sibling temporary directory;
//!   - atomically rename the stage into place (POSIX directory rename);
//!   - on failed publication, restore the previous output reliably and never
//!     silently discard a restoration failure;
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

/// True when the directory carries the exact ownership marker: the file
/// exists **and** its bytes equal `util.output_owner_marker_content`. A
/// wrong-name marker, a marker with wrong content, or an unreadable/oversized
/// marker all count as unowned.
fn validateOwnershipMarker(io: std.Io, dir: std.Io.Dir) bool {
    var file = dir.openFile(io, util.output_owner_marker, .{}) catch return false;
    defer file.close(io);
    var reader = file.reader(io, &.{});
    const bytes = reader.interface.allocRemaining(std.heap.page_allocator, .limited(util.max_marker_bytes)) catch return false;
    defer std.heap.page_allocator.free(bytes);
    return util.eql(bytes, util.output_owner_marker_content);
}

/// Validate the final output path: refuse non-empty directories that do not
/// carry the validated ownership marker. Also clears any leftover owned stage.
/// Every directory checked here is opened with `.iterate = true` because
/// `dirIsEmpty` iterates it (required on Linux; macOS tolerates the missing
/// flag, and the CI lane caught the difference).
pub fn prepareOwnedStage(io: std.Io, final_path: []const u8, stage_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.openDir(io, final_path, .{ .iterate = true })) |final_dir| {
        defer final_dir.close(io);
        if (!dirIsEmpty(io, final_dir) and !validateOwnershipMarker(io, final_dir)) {
            return error.RefuseUnownedOutput;
        }
    } else |_| {}
    if (cwd.openDir(io, stage_path, .{ .iterate = true })) |stage_dir| {
        defer stage_dir.close(io);
        if (!dirIsEmpty(io, stage_dir) and !validateOwnershipMarker(io, stage_dir)) {
            return error.RefuseUnownedStage;
        }
        cwd.deleteTree(io, stage_path) catch return error.StageCleanupFailed;
    } else |_| {}
    try cwd.createDirPath(io, stage_path);
}

/// Atomically publish the stage as the final output.
///
/// The backup path is **never** deleted unconditionally: an existing backup is
/// only removed when it is empty or carries the validated ownership marker.
/// An unrelated directory (and its files) at the backup path causes a refusal
/// and survives unchanged.
///
/// On failure the previous output (if any) is moved back from the backup path;
/// a restoration failure is reported as `error.BackupRestoreFailed` and is
/// never silently discarded. The stage is removed after a failed publish.
pub fn publishOwnedStage(io: std.Io, final_path: []const u8, stage_path: []const u8, backup_path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();

    // A non-directory at the backup path is never ours: `openDir` would fail
    // on a plain file, and the later rename would silently replace it. Refuse
    // any non-directory (or unreadable) entry at the backup path outright.
    if (cwd.statFile(io, backup_path, .{})) |st| {
        if (st.kind != .directory) return error.RefuseUnownedBackup;
    } else |_| {}
    if (cwd.openDir(io, backup_path, .{ .iterate = true })) |backup_dir| {
        defer backup_dir.close(io);
        if (!dirIsEmpty(io, backup_dir) and !validateOwnershipMarker(io, backup_dir)) {
            return error.RefuseUnownedBackup;
        }
        cwd.deleteTree(io, backup_path) catch return error.BackupCleanupFailed;
    } else |_| {}

    // Move the previous final tree aside (only when one exists).
    var moved_previous = false;
    if (cwd.openDir(io, final_path, .{})) |final_dir| {
        final_dir.close(io);
        try cwd.rename(final_path, cwd, backup_path, io);
        moved_previous = true;
    } else |_| {}

    // Move the stage into place.
    cwd.rename(stage_path, cwd, final_path, io) catch |err| {
        if (moved_previous) {
            // Restoration failure is surfaced, never discarded: the previous
            // report stays at the backup path (recoverable) and the caller
            // receives an actionable error.
            cwd.rename(backup_path, cwd, final_path, io) catch return error.BackupRestoreFailed;
        }
        // No previous output to restore: remove the abandoned stage so nothing
        // half-published remains.
        cwd.deleteTree(io, stage_path) catch {};
        return err;
    };

    // Success: drop the backup copy (already validated as ours).
    if (moved_previous) {
        cwd.deleteTree(io, backup_path) catch return error.BackupCleanupFailed;
    }
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

test "marker filename without marker content is refused" {
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
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/precious.txt", .{final_path}), .data = "mine" });
    // A marker file with the right name but the wrong bytes must be refused.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ final_path, util.output_owner_marker }), .data = "format=someone-else\n" });
    try std.testing.expectError(error.RefuseUnownedOutput, prepareOwnedStage(io, final_path, stage_path));
    // The unrelated file survives.
    const precious = try readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/precious.txt", .{final_path}), a);
    try std.testing.expectEqualStrings("mine", precious);
}

test "unrelated backup directory survives publish refusal" {
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
    // A valid owned final output.
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{\"v\":1}");
    try publishOwnedStage(io, final_path, stage_path, backup_path);
    // An unrelated, unmarked directory at the backup path.
    try std.Io.Dir.cwd().createDirPath(io, backup_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/unrelated.txt", .{backup_path}), .data = "keep me" });
    // Publish must refuse instead of deleting the unrelated backup.
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{\"v\":2}");
    try std.testing.expectError(error.RefuseUnownedBackup, publishOwnedStage(io, final_path, stage_path, backup_path));
    // The unrelated backup and its file survive unchanged; final is untouched.
    const kept = try readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/unrelated.txt", .{backup_path}), a);
    try std.testing.expectEqualStrings("keep me", kept);
    const final_data = try readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{final_path}), a);
    try std.testing.expectEqualStrings("{\"v\":1}", final_data);
}

test "unrelated file at backup path is refused, not replaced" {
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
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{\"v\":1}");
    try publishOwnedStage(io, final_path, stage_path, backup_path);
    // An unrelated regular *file* (not a directory) at the backup path.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = backup_path, .data = "someone else's file" });
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{\"v\":2}");
    try std.testing.expectError(error.RefuseUnownedBackup, publishOwnedStage(io, final_path, stage_path, backup_path));
    // The unrelated file survives byte-for-byte; final is untouched.
    const kept = try readFileAlloc(io, std.Io.Dir.cwd(), backup_path, a);
    try std.testing.expectEqualStrings("someone else's file", kept);
    const final_data = try readFileAlloc(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{final_path}), a);
    try std.testing.expectEqualStrings("{\"v\":1}", final_data);
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
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/report.json", .{stage_path}), "{}");
    try publishOwnedStage(io, final_path, stage_path, backup_path);
    try std.testing.expect((std.Io.Dir.cwd().openDir(io, final_path, .{}) catch null) != null);
    // Second publish over the marked output; the owned backup is replaced.
    try prepareOwnedStage(io, final_path, stage_path);
    try writeBytes(io, std.Io.Dir.cwd(), try std.fmt.allocPrint(a, "{s}/{s}", .{ stage_path, util.output_owner_marker }), util.output_owner_marker_content);
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
