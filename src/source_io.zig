//! Bounded reads for discovered authoring sources.

const std = @import("std");
const Io = std.Io;
const page = @import("page.zig");

/// Read a page source while preserving the parser's oversized-source
/// diagnostic. At most `max_source_bytes + 1` bytes are ever allocated.
pub fn readPageAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.SourceTooLarge;
    var reader = file.reader(io, &.{});
    if (size <= page.max_source_bytes) return try reader.interface.readAlloc(allocator, size);

    const prefix = try allocator.alloc(u8, page.max_source_bytes + 1);
    errdefer allocator.free(prefix);
    try reader.interface.readSliceAll(prefix);
    return prefix;
}

test "readPageAlloc bounds oversized source allocation" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/oversized.md", .{tmp.sub_path});
    defer gpa.free(rel);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(rel)) |parent| try cwd.createDirPath(io, parent);
    const oversized = try gpa.alloc(u8, page.max_source_bytes + 1);
    defer gpa.free(oversized);
    @memset(oversized, 'x');
    try cwd.writeFile(io, .{ .sub_path = rel, .data = oversized });
    const got = try readPageAlloc(io, cwd, rel, gpa);
    defer gpa.free(got);
    try std.testing.expectEqual(page.max_source_bytes + 1, got.len);
}
