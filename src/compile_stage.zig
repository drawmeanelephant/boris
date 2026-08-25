const std = @import("std");
const Io = std.Io;

/// Publish all files under `stage_dir` into `final_dir` via same-parent rename.
pub fn ensureValidParentDirs(io: Io, final_dir: Io.Dir, parent_rel: []const u8) !void {
    if (parent_rel.len == 0 or std.mem.eql(u8, parent_rel, ".")) return;

    var start: usize = 0;
    while (start < parent_rel.len) {
        if (parent_rel[start] == '/' or parent_rel[start] == '\\') {
            start += 1;
            continue;
        }
        const slash = std.mem.indexOfAnyPos(u8, parent_rel, start, "/\\") orelse parent_rel.len;
        const progressive = parent_rel[0..slash];
        if (progressive.len > 0 and !std.mem.eql(u8, progressive, ".") and !std.mem.eql(u8, progressive, "..")) {
            if (final_dir.statFile(io, progressive, .{ .follow_symlinks = false })) |st| {
                if (st.kind == .sym_link or st.kind != .directory) {
                    return error.TargetOutputSymlink;
                }
            } else |err| switch (err) {
                error.FileNotFound => {
                    final_dir.createDir(io, progressive, .default_dir) catch |mk_err| switch (mk_err) {
                        error.PathAlreadyExists => {
                            const re_st = final_dir.statFile(io, progressive, .{ .follow_symlinks = false }) catch return mk_err;
                            if (re_st.kind == .sym_link or re_st.kind != .directory) {
                                return error.TargetOutputSymlink;
                            }
                        },
                        else => return mk_err,
                    };
                },
                else => return err,
            }
        }
        if (slash >= parent_rel.len) break;
        start = slash + 1;
    }
}

/// Creates intermediate directories under `final_dir` as needed, rejecting any
/// symlinks or non-directory components along destination parent paths (H-03).
///
/// Prefer rename (atomic-ish on same filesystem). On `error.CrossDevice` (and
/// only that), fall back to `copyFile` + delete source. Cross-volume **atomic**
/// replace is still not claimed — the fallback is best-effort completeness.
pub fn publishStageFile(
    io: Io,
    source_dir: Io.Dir,
    source_path: []const u8,
    final_dir: Io.Dir,
    final_path: []const u8,
) !void {
    if (std.fs.path.dirname(final_path)) |parent| {
        if (parent.len > 0) try ensureValidParentDirs(io, final_dir, parent);
    }
    source_dir.rename(source_path, final_dir, final_path, io) catch |err| switch (err) {
        error.CrossDevice => {
            try source_dir.copyFile(source_path, final_dir, final_path, io, .{
                .make_path = false,
                .replace = true,
            });
            source_dir.deleteFile(io, source_path) catch {};
        },
        else => return err,
    };
}

fn publishPathsEqual(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_byte, right_byte| {
        if (left_byte == right_byte) continue;
        if ((left_byte == '/' and right_byte == '\\') or
            (left_byte == '\\' and right_byte == '/')) continue;
        return false;
    }
    return true;
}

/// Publish all files under `stage_dir` into `final_dir` via same-parent rename.
/// When `deferred_path` is set, that file is committed only after every other
/// staged payload has replaced successfully. The HTML coordinator uses this
/// for the artifact inventory so a later payload replacement failure cannot
/// expose an inventory for a partially committed target.
pub fn publishStageTree(
    io: Io,
    gpa: std.mem.Allocator,
    stage_dir: Io.Dir,
    final_dir: Io.Dir,
    deferred_path: ?[]const u8,
) !void {
    var walker = try stage_dir.walkSelectively(gpa);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) {
            try walker.enter(io, entry);
            continue;
        }
        if (entry.kind != .file) continue;
        if (deferred_path) |path| {
            if (publishPathsEqual(entry.path, path)) continue;
        }
        try publishStageFile(io, entry.dir, entry.basename, final_dir, entry.path);
    }

    if (deferred_path) |path| {
        try publishStageFile(io, stage_dir, path, final_dir, path);
    }
}
