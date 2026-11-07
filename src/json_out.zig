//! Deterministic pretty-printed JSON helpers (2-space indent, LF, fixed key order).
//!
//! No dependency on `std.json` stringify order — keys are written explicitly.

const std = @import("std");
const encode = @import("encode.zig");

pub fn escapeAppend(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    var output: ListWriter = .{ .buf = buf, .gpa = gpa };
    escapeWrite(&output.writer, s) catch return error.OutOfMemory;
}

const ListWriter = struct {
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    writer: std.Io.Writer = .{ .buffer = &.{}, .vtable = &.{ .drain = drain } },

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *@This() = @fieldParentPtr("writer", writer);
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            // Preserve ArrayList growth history for arena-backed evidence writers.
            for (part) |byte| self.buf.append(self.gpa, byte) catch return error.WriteFailed;
            written += part.len;
        }
        for (0..splat) |_| {
            for (data[data.len - 1]) |byte| self.buf.append(self.gpa, byte) catch return error.WriteFailed;
            written += data[data.len - 1].len;
        }
        return written;
    }
};

fn escapeWrite(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    var start: usize = 0;
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
            try std.json.Stringify.encodeJsonStringChars(s[start..i], .{}, writer);
            try writer.writeAll(sep.json_escape);
            i += sep.len;
            start = i;
            continue;
        }
        // Preserve the existing byte representation instead of std's \b/\f.
        if (s[i] == 0x08 or s[i] == 0x0c) {
            try std.json.Stringify.encodeJsonStringChars(s[start..i], .{}, writer);
            try writer.writeAll(if (s[i] == 0x08) "\\u0008" else "\\u000c");
            start = i + 1;
        }
        i += 1;
    }
    try std.json.Stringify.encodeJsonStringChars(s[start..], .{}, writer);
}

pub fn indent(buf: *std.ArrayList(u8), gpa: std.mem.Allocator, level: usize) !void {
    var i: usize = 0;
    while (i < level) : (i += 1) {
        try buf.appendSlice(gpa, "  ");
    }
}

/// Write the same JSON string bytes directly to any writer.
pub fn writeStringTo(writer: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    try escapeWrite(writer, s);
    try writer.writeByte('"');
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

test "stdlib JSON escaping preserves existing control and UTF-8 bytes" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try escapeAppend(&buf, gpa, "\x00\x08\x0c\x1f\n\r\t\"\\é");
    try std.testing.expectEqualStrings("\\u0000\\u0008\\u000c\\u001f\\n\\r\\t\\\"\\\\é", buf.items);
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
