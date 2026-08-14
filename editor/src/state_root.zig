//! Disposable editor state location. Computing this path performs no I/O.

const std = @import("std");
const builtin = @import("builtin");

pub const Environment = struct {
    home: ?[]const u8 = null,
    xdg_cache_home: ?[]const u8 = null,
    local_app_data: ?[]const u8 = null,
};

pub fn fromProcess(map: *const std.process.Environ.Map) Environment {
    return .{
        .home = map.get("HOME"),
        .xdg_cache_home = map.get("XDG_CACHE_HOME"),
        .local_app_data = map.get("LOCALAPPDATA"),
    };
}

pub fn compute(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    environment: Environment,
) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_path, &digest, .{});
    var key: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&key, "{x}", .{digest[0..16]}) catch unreachable;

    const base = switch (builtin.os.tag) {
        .windows => environment.local_app_data orelse return error.CacheRootUnavailable,
        .macos => blk: {
            const home = environment.home orelse return error.CacheRootUnavailable;
            break :blk try std.fs.path.join(allocator, &.{ home, "Library", "Caches" });
        },
        else => environment.xdg_cache_home orelse blk: {
            const home = environment.home orelse return error.CacheRootUnavailable;
            break :blk try std.fs.path.join(allocator, &.{ home, ".cache" });
        },
    };
    defer if (builtin.os.tag == .macos or (builtin.os.tag != .windows and environment.xdg_cache_home == null)) allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, "boris-editor", &key });
}

test "state roots are stable and project-keyed" {
    const allocator = std.testing.allocator;
    const env: Environment = .{ .home = "/home/author", .xdg_cache_home = "/cache", .local_app_data = "C:\\cache" };
    const first = try compute(allocator, "/projects/a", env);
    defer allocator.free(first);
    const again = try compute(allocator, "/projects/a", env);
    defer allocator.free(again);
    const other = try compute(allocator, "/projects/b", env);
    defer allocator.free(other);
    try std.testing.expectEqualStrings(first, again);
    try std.testing.expect(!std.mem.eql(u8, first, other));
    try std.testing.expect(std.mem.indexOf(u8, first, "boris-editor") != null);
}
