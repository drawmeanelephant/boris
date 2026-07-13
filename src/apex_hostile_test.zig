//! Integration tests against the hostile Apex C test double.
//!
//! Built only via `zig build test-apex-hostile`, which links
//! `vendor/apex/apex_hostile.c` instead of the real engine.
//!
//! Proves the Zig wrapper (`apex.zig`) never constructs slices from dirty
//! error outputs and rejects success+null+nonzero-length.

const std = @import("std");
// Named import from build.zig (`imports = &.{ .{ .name = "apex", ... } }`) so
// this binary links the hostile C double attached to that module instance.
const apex = @import("apex");

test "hostile apex version is the test double" {
    const v = apex.version();
    try std.testing.expect(std.mem.indexOf(u8, v, "hostile") != null);
}

test "hostile OOM: dirty outputs never become Html" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.OutOfMemory, apex.render("@HOSTILE_OOM\n", &arena));
}

test "hostile ARGS: dirty outputs never become Html" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.RenderFailed, apex.render("@HOSTILE_ARGS\n", &arena));
}

test "hostile unknown status: dirty outputs never become Html" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.RenderFailed, apex.render("@HOSTILE_UNKNOWN_ERR\n", &arena));
}

test "hostile success null+nonzero length is rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.RenderFailed, apex.render("@HOSTILE_NULL_LEN\n", &arena));
}

test "hostile benign success returns html via arena" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try apex.render("# hello\n", &arena);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "hostile-ok") != null);
}

test "hostile empty input is ok" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try apex.render("", &arena);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}
