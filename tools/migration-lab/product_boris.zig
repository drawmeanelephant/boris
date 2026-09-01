// Resolve the product `boris` binary used by black-box compile tests.
//
// The laboratory does not build the product binary (docs/plans/
// migration-lab-standalone-repo.md, 3.2): it is a pinned external
// prerequisite, like `zig` itself. CI installs a pinned Boris release and
// exports `BORIS_BIN`; local runs may rely on `boris` on PATH. This resolver
// never reaches outside the laboratory tree (no `../..` probes).
//
// Zig 0.16 exposes the process environment only through `main`'s `Init`, so
// `build.zig` snapshots `BORIS_BIN` and `PATH` from the build graph into the
// `options` module at configure time and this module reads those snapshots.
const std = @import("std");
const Io = std.Io;
const options = @import("options");

const configured_boris_bin: []const u8 = options.boris_bin;
const configured_path: []const u8 = options.path;

/// Resolution order:
///   1. `BORIS_BIN` environment variable (explicit pin; CI sets it).
///   2. A `boris` executable on PATH.
/// Returns null when neither is available.
pub fn resolve(io: Io, gpa: std.mem.Allocator) !?[]const u8 {
    if (configured_boris_bin.len > 0) return configured_boris_bin;

    if (findOnPath(io, gpa)) |p| {
        if (p.len > 0) return p;
    } else |_| {}

    return null;
}

/// True when the resolver produced a usable path or a PATH-resolvable name.
pub fn available(io: Io, gpa: std.mem.Allocator) bool {
    return (resolve(io, gpa) catch null) != null;
}

fn findOnPath(io: Io, gpa: std.mem.Allocator) !?[]const u8 {
    const path_env = configured_path;
    if (path_env.len == 0) return null;

    const exe_name = if (builtin.os.tag == .windows) "boris.exe" else "boris";
    var it = std.mem.splitScalar(u8, path_env, std.fs.path.delimiter);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(gpa, "{s}{c}{s}", .{ dir, std.fs.path.sep, exe_name });
        defer gpa.free(candidate);
        var f = Io.Dir.cwd().openFile(io, candidate, .{}) catch continue;
        f.close(io);
        return try gpa.dupe(u8, candidate);
    }
    return null;
}

const builtin = @import("builtin");
