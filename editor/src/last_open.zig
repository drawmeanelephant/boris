//! Last-opened author path, stored under the disposable editor state root.
//! Never project truth: a missing, corrupt, or unsafe file is ignored.

const std = @import("std");
const Io = std.Io;
const file_api = @import("file_api.zig");

const file_name = "last-open.json";

const Document = struct {
    path: []const u8,
};

pub fn save(allocator: std.mem.Allocator, io: Io, state_root: []const u8, path: []const u8) !void {
    try file_api.validatePath(path);
    try Io.Dir.cwd().createDirPath(io, state_root);
    var dir = try Io.Dir.cwd().openDir(io, state_root, .{ .follow_symlinks = false });
    defer dir.close(io);

    const bytes = try std.json.Stringify.valueAlloc(allocator, .{ .path = path }, .{});
    defer allocator.free(bytes);
    var atomic = try dir.createFileAtomic(io, file_name, .{ .replace = true });
    defer atomic.deinit(io);
    var write_buffer: [1024]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buffer);
    try writer.interface.writeAll(bytes);
    try writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

pub fn load(allocator: std.mem.Allocator, io: Io, state_root: []const u8) std.mem.Allocator.Error!?[]u8 {
    var dir = Io.Dir.cwd().openDir(io, state_root, .{ .follow_symlinks = false }) catch return null;
    defer dir.close(io);
    const bytes = dir.readFileAlloc(io, file_name, allocator, .limited(8192)) catch return null;
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(Document, allocator, bytes, .{}) catch return null;
    defer parsed.deinit();
    file_api.validatePath(parsed.value.path) catch return null;
    return try allocator.dupe(u8, parsed.value.path);
}

pub fn clear(io: Io, state_root: []const u8) !void {
    var dir = Io.Dir.cwd().openDir(io, state_root, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |other| return other,
    };
    defer dir.close(io);
    dir.deleteFile(io, file_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |other| return other,
    };
}

test "last-open path survives a new store instance" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try std.testing.expect(try load(allocator, io, root) == null);
    try save(allocator, io, root, "content/guides/start.md");
    const loaded = try load(allocator, io, root);
    defer if (loaded) |path| allocator.free(path);
    try std.testing.expectEqualStrings("content/guides/start.md", loaded.?);
    try clear(io, root);
    try std.testing.expect(try load(allocator, io, root) == null);
}

test "unsafe last-open files are ignored" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const root = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);

    try std.testing.expectError(error.PathNotAuthorOwned, save(allocator, io, root, "dist/index.html"));
    try std.testing.expectError(error.InvalidPath, save(allocator, io, root, "../secret"));

    try Io.Dir.cwd().createDirPath(io, root);
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .follow_symlinks = false });
    defer dir.close(io);
    try dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"path\":\"dist/index.html\"}" });
    try std.testing.expect(try load(allocator, io, root) == null);
    try dir.writeFile(io, .{ .sub_path = file_name, .data = "{not-json" });
    try std.testing.expect(try load(allocator, io, root) == null);
}
