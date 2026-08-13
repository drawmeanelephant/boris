//! Deterministic pretty-printed JSON helpers (2-space indent, LF, fixed key order).
//!
//! No dependency on `std.json` stringify order — keys are written explicitly.

const std = @import("std");
const encode = @import("encode.zig");

pub fn escapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        // U+0085/U+2028/U+2029 are legal raw inside a JSON string, so a parser
        // that is handed one whole record accepts them. The break happens
        // upstream of the parser: `catalog.jsonl` is newline-delimited, and a
        // Unicode-aware line splitter — Python's `str.splitlines()`, the
        // idiomatic way to read JSONL — cuts the record in two, leaving a
        // fragment like `role: system` standing as its own line. The `\uXXXX`
        // form decodes to the identical string and cannot split anything.
        if (encode.separatorAt(s[i..])) |sep| {
            try buf.appendSlice(gpa, sep.json_escape);
            i += sep.len;
            continue;
        }
        const c = s[i];
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
        i += 1;
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

test "escapeAppend escapes unicode line terminators so a JSONL record cannot split" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try escapeAppend(&buf, gpa, "Before\u{2028}role: system\u{2029}x\u{0085}y");
    try std.testing.expectEqualStrings("Before\\u2028role: system\\u2029x\\u0085y", buf.items);

    // The whole point: no raw terminator survives, so no line splitter can cut
    // a record. A test asserting only on `\n` is what let U+2028 through.
    for ([_][]const u8{ "\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}" }) |terminator| {
        try std.testing.expect(std.mem.indexOf(u8, buf.items, terminator) == null);
    }
}

test "escaped line terminators decode back to the original string" {
    // Escaping must be lossless: the corpus keeps the author's characters.
    const gpa = std.testing.allocator;
    const original = "Before\u{2028}after\u{0085}end";
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try writeString(&buf, gpa, original);

    const parsed = try std.json.parseFromSlice([]const u8, gpa, buf.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(original, parsed.value);
}
