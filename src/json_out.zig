//! Deterministic pretty-printed JSON helpers (2-space indent, LF, fixed key order).
//!
//! No dependency on `std.json` stringify order — keys are written explicitly.

const std = @import("std");

pub fn escapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(gpa, "\\\""),
            '\\' => try buf.appendSlice(gpa, "\\\\"),
            '\n' => try buf.appendSlice(gpa, "\\n"),
            '\r' => try buf.appendSlice(gpa, "\\r"),
            '\t' => try buf.appendSlice(gpa, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const piece = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(gpa, piece);
                } else {
                    try buf.append(gpa, c);
                }
            },
        }
    }
}

pub fn indent(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try buf.appendSlice(gpa, "  ");
    }
}

pub fn writeString(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    try buf.append(gpa, '"');
    try escapeAppend(buf, gpa, s);
    try buf.append(gpa, '"');
}

pub fn writeNull(buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try buf.appendSlice(gpa, "null");
}

pub fn writeBool(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(gpa, if (v) "true" else "false");
}

pub fn writeUsize(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: usize) !void {
    var tmp: [32]u8 = undefined;
    const piece = try std.fmt.bufPrint(&tmp, "{d}", .{v});
    try buf.appendSlice(gpa, piece);
}

pub fn writeOptionalU32(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, v: ?u32) !void {
    if (v) |n| {
        var tmp: [16]u8 = undefined;
        const piece = try std.fmt.bufPrint(&tmp, "{d}", .{n});
        try buf.appendSlice(gpa, piece);
    } else {
        try writeNull(buf, gpa);
    }
}

test "escapeAppend quotes and newlines" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try escapeAppend(&buf, gpa, "a\"b\nc");
    try std.testing.expectEqualStrings("a\\\"b\\nc", buf.items);
}
