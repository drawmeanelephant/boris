//! Source bytes and source spans.
//!
//! Oliver parses a single in-memory byte slice. All source locations are
//! expressed as half-open byte ranges (`[start, end)`) into that slice, so
//! nodes and diagnostics carry cheap, precise positions without copying text.
//!
//! Offsets are `u32`. `max_input_len` bounds the input so every offset fits;
//! `oliver.parse` rejects larger inputs with `error.InputTooLarge` rather
//! than silently wrapping.

const std = @import("std");

/// Maximum accepted input size in bytes. Every span offset must be
/// representable as `u32`, so the input must be smaller than 4 GiB.
/// A 4 GiB in-memory document is far beyond any realistic use; the bound
/// keeps spans 8 bytes wide and arithmetic overflow-free.
pub const max_input_len: usize = std.math.maxInt(u32);

/// Half-open byte range `[start, end)` into the document source.
pub const Span = struct {
    start: u32,
    end: u32,

    pub fn len(self: Span) usize {
        return self.end - self.start;
    }

    pub fn isEmpty(self: Span) bool {
        return self.start == self.end;
    }
};

/// The source byte slice, plus helpers for interpreting offsets.
pub const Source = struct {
    bytes: []const u8,

    pub fn span(self: Source, s: Span) []const u8 {
        return self.bytes[s.start..s.end];
    }

    /// 1-based line and column of a byte offset. Scans from the start of the
    /// document; used only when diagnostics are materialized, so the linear
    /// cost is acceptable. Treats `\n`, `\r\n`, and `\r` as line endings.
    pub fn lineCol(self: Source, offset: u32) LineCol {
        var line: u32 = 1;
        var column: u32 = 1;
        var i: usize = 0;
        const end = @min(offset, self.bytes.len);
        while (i < end) : (i += 1) {
            switch (self.bytes[i]) {
                '\n' => {
                    line += 1;
                    column = 1;
                },
                '\r' => {
                    if (i + 1 < end and self.bytes[i + 1] == '\n') i += 1;
                    line += 1;
                    column = 1;
                },
                else => column += 1,
            }
        }
        return .{ .line = line, .column = column };
    }
};

/// 1-based line and column.
pub const LineCol = struct {
    line: u32,
    column: u32,
};

/// One line of the source: content bytes (without the terminator), plus the
/// byte offsets needed to build spans and to recover the terminator region.
pub const Line = struct {
    /// Content bytes, excluding the line terminator.
    text: []const u8,
    /// Byte offset of `text`'s first byte.
    start: usize,
    /// Byte offset just past the last content byte.
    content_end: usize,
    /// Byte offset just past the terminator (start of the next line, or
    /// end of input for a final unterminated line).
    end: usize,

    /// Span of the content, excluding the terminator.
    pub fn contentSpan(self: Line) Span {
        return .{ .start = @intCast(self.start), .end = @intCast(self.content_end) };
    }

    /// Span of the line terminator region (`\n`, `\r\n`, or `\r`); empty for
    /// a final line without a terminator.
    pub fn terminatorSpan(self: Line) Span {
        return .{ .start = @intCast(self.content_end), .end = @intCast(self.end) };
    }
};

/// Iterates over lines, treating `\n`, `\r\n`, and `\r` each as a single
/// line ending (matching the CommonMark definition of "line ending").
/// A trailing terminator does not produce an empty final line.
pub const Lines = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn init(bytes: []const u8) Lines {
        return .{ .bytes = bytes };
    }

    pub fn next(self: *Lines) ?Line {
        if (self.pos >= self.bytes.len) return null;
        const start = self.pos;
        var i = self.pos;
        while (i < self.bytes.len) : (i += 1) {
            const b = self.bytes[i];
            if (b == '\n' or b == '\r') break;
        }
        const content_end = i;
        if (i < self.bytes.len) {
            if (self.bytes[i] == '\r' and i + 1 < self.bytes.len and self.bytes[i + 1] == '\n') {
                i += 1;
            }
            i += 1;
        }
        self.pos = i;
        return .{
            .text = self.bytes[start..content_end],
            .start = start,
            .content_end = content_end,
            .end = i,
        };
    }
};

test "lines: LF, CRLF, CR, trailing terminator, empty input" {
    {
        var it = Lines.init("a\nb\r\nc\rd");
        const a = it.next().?;
        try std.testing.expectEqualStrings("a", a.text);
        try std.testing.expectEqual(@as(usize, 0), a.start);
        try std.testing.expectEqual(@as(usize, 1), a.content_end);
        try std.testing.expectEqual(@as(usize, 2), a.end);
        const b = it.next().?;
        try std.testing.expectEqualStrings("b", b.text);
        try std.testing.expectEqual(@as(usize, 2), b.start);
        try std.testing.expectEqual(@as(usize, 5), b.end); // \r\n counted once
        const c = it.next().?;
        try std.testing.expectEqualStrings("c", c.text);
        try std.testing.expectEqual(@as(usize, 5), c.start);
        try std.testing.expectEqual(@as(usize, 7), c.end); // \r counted once
        const d = it.next().?;
        try std.testing.expectEqualStrings("d", d.text);
        try std.testing.expectEqual(@as(usize, 7), d.start);
        try std.testing.expectEqual(@as(usize, 8), d.end);
        try std.testing.expectEqual(@as(?Line, null), it.next());
    }
    {
        // A trailing terminator does not yield an empty final line.
        var it = Lines.init("a\n");
        const a = it.next().?;
        try std.testing.expectEqualStrings("a", a.text);
        try std.testing.expectEqual(@as(usize, 2), a.end);
        try std.testing.expectEqual(@as(?Line, null), it.next());
    }
    {
        var it = Lines.init("");
        try std.testing.expectEqual(@as(?Line, null), it.next());
    }
    {
        var it = Lines.init("\n\n");
        try std.testing.expectEqualStrings("", it.next().?.text);
        try std.testing.expectEqualStrings("", it.next().?.text);
        try std.testing.expectEqual(@as(?Line, null), it.next());
    }
}

test "lineCol: 1-based positions, CRLF counted once" {
    const src = Source{ .bytes = "ab\r\ncd\nef" };
    try std.testing.expectEqual(LineCol{ .line = 1, .column = 1 }, src.lineCol(0));
    try std.testing.expectEqual(LineCol{ .line = 1, .column = 2 }, src.lineCol(1));
    try std.testing.expectEqual(LineCol{ .line = 2, .column = 1 }, src.lineCol(4)); // after \r\n
    try std.testing.expectEqual(LineCol{ .line = 2, .column = 2 }, src.lineCol(5));
    try std.testing.expectEqual(LineCol{ .line = 3, .column = 1 }, src.lineCol(7));
    try std.testing.expectEqual(LineCol{ .line = 3, .column = 3 }, src.lineCol(9));
}
