const std = @import("std");
const contracts = @import("contracts.zig");
const project = @import("project.zig");
const security = @import("security.zig");
const server = @import("server.zig");
const state_root = @import("state_root.zig");

pub const editor_version = server.editor_id;

const Options = struct {
    project_root: []const u8 = ".",
    ui_dir: []const u8 = "editor/ui/dist",
    boris_path: []const u8 = "boris",
    port: u16 = 0,
    help: bool = false,
};

pub fn main(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 3;
    const options = parseOptions(args) catch |err| {
        std.debug.print("boris-editor: {s}\n", .{@errorName(err)});
        printUsage();
        return 2;
    };
    if (options.help) {
        printUsage();
        return 0;
    }

    const canonical_project = std.Io.Dir.cwd().realPathFileAlloc(init.io, options.project_root, allocator) catch |err| {
        std.debug.print("boris-editor: cannot open project: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer allocator.free(canonical_project);

    const boris_path = resolveBorisPath(allocator, init.io, options.boris_path) catch |err| {
        std.debug.print("boris-editor: cannot resolve --boris '{s}': {s}\n", .{ options.boris_path, @errorName(err) });
        return 2;
    };
    defer allocator.free(boris_path);

    const found = project.discover(init.io, canonical_project) catch |err| {
        std.debug.print("boris-editor: project discovery failed: {s}\n", .{@errorName(err)});
        return 3;
    };
    if (!found.isProject()) {
        std.debug.print("boris-editor: {s} has no content directory\n", .{canonical_project});
        return 2;
    }

    const cache_path = state_root.compute(allocator, canonical_project, state_root.fromProcess(init.environ_map)) catch |err| {
        std.debug.print("boris-editor: state root unavailable: {s}\n", .{@errorName(err)});
        return 3;
    };
    defer allocator.free(cache_path);

    var random_bytes: [16]u8 = undefined;
    init.io.randomSecure(&random_bytes) catch |err| {
        std.debug.print("boris-editor: secure session token unavailable: {s}\n", .{@errorName(err)});
        return 3;
    };
    var token: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&token, "{x}", .{random_bytes}) catch unreachable;

    server.serve(init.io, allocator, .{
        .project_root = canonical_project,
        .ui_dir = options.ui_dir,
        .boris_path = boris_path,
        .port = options.port,
        .token = token,
    }) catch |err| {
        std.debug.print("boris-editor: host failed: {s}\n", .{@errorName(err)});
        return 3;
    };
    return 0;
}

fn parseOptions(args: []const []const u8) !Options {
    var options: Options = .{};
    var project_seen = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--ui-dir")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.ui_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--boris")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.boris_path = args[i];
        } else if (std.mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            options.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownFlag;
        } else if (!project_seen) {
            options.project_root = arg;
            project_seen = true;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return options;
}

fn printUsage() void {
    std.debug.print(
        \\Usage: boris-editor [DIR] [--boris PATH] [--ui-dir DIR] [--port PORT]
        \\
        \\Serves the Boris Editor on 127.0.0.1. DIR defaults to the current directory.
        \\
    , .{});
}

/// Resolves the --boris value into a path the host can spawn. A bare command
/// name (no path separator) is passed through for PATH lookup; a path-like
/// value is canonicalized against the editor's current directory so that child
/// processes spawned with a different cwd (the project root) still find it.
fn resolveBorisPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    if (std.mem.indexOfAny(u8, path, "/\\") == null) return allocator.dupeZ(u8, path);
    return std.Io.Dir.cwd().realPathFileAlloc(io, path, allocator) catch return error.BorisPathUnresolvable;
}

test "CLI accepts one project and explicit host options" {
    const options = try parseOptions(&.{ "boris-editor", "site", "--port", "0", "--boris", "./zig-out/bin/boris" });
    try std.testing.expectEqualStrings("site", options.project_root);
    try std.testing.expectEqual(@as(u16, 0), options.port);
    try std.testing.expectError(error.UnexpectedArgument, parseOptions(&.{ "boris-editor", "a", "b" }));
}

test "boris path resolution canonicalizes paths and passes through command names" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const bare = try resolveBorisPath(allocator, io, "boris");
    defer allocator.free(bare);
    try std.testing.expectEqualStrings("boris", bare);

    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(io, .{ .sub_path = "boris.bin", .data = "" });
    const absolute = try temp.dir.realPathFileAlloc(io, "boris.bin", allocator);
    defer allocator.free(absolute);
    const resolved = try resolveBorisPath(allocator, io, absolute);
    defer allocator.free(resolved);
    try std.testing.expectEqualStrings(absolute, resolved);
    try std.testing.expect(std.fs.path.isAbsolute(resolved));

    try std.testing.expectError(error.BorisPathUnresolvable, resolveBorisPath(allocator, io, "no/such/binary"));
}

test {
    _ = contracts;
    _ = security;
}
