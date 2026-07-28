//! Markdown body text transforms for the RAG corpus.
//!
//! Split out of `rag_emit.zig` so that module can hold a strict "every byte
//! goes through `structured_out.Sink`" rule (see `emitter_discipline_test.zig`).
//! This module is not an emitter: it rewrites page body markdown and produces a
//! fragment that `rag_emit` then inserts verbatim, by design.

const std = @import("std");
const aside = @import("aside.zig");

pub fn isAtxH1Line(left_trimmed: []const u8) bool {
    if (left_trimmed.len == 0 or left_trimmed[0] != '#') return false;
    if (left_trimmed.len >= 2 and left_trimmed[1] == '#') return false;
    return left_trimmed.len == 1 or left_trimmed[1] == ' ' or left_trimmed[1] == '\t';
}

pub fn stripLeadingAtxH1(body: []const u8) []const u8 {
    var i: usize = 0;
    while (i < body.len) {
        var end = i;
        while (end < body.len and body[end] != '\n') : (end += 1) {}
        var line = body[i..end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) {
            i = if (end < body.len) end + 1 else body.len;
            continue;
        }
        if (isAtxH1Line(trimmed)) return if (end < body.len) body[end + 1 ..] else body[end..];
        return body;
    }
    return body;
}

pub fn demoteAtxH1ToH2(body: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < body.len) {
        var end = i;
        while (end < body.len and body[end] != '\n') : (end += 1) {}
        var line = body[i..end];
        var had_cr = false;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
            had_cr = true;
        }
        const left = std.mem.trimStart(u8, line, " \t");
        if (isAtxH1Line(left)) {
            try out.appendSlice(allocator, line[0 .. line.len - left.len]);
            try out.append(allocator, '#');
            try out.appendSlice(allocator, left);
        } else try out.appendSlice(allocator, line);
        if (had_cr) try out.append(allocator, '\r');
        if (end < body.len) {
            try out.append(allocator, '\n');
            i = end + 1;
        } else i = end;
    }
    return try out.toOwnedSlice(allocator);
}

/// Render parsed segments back to markdown: H1-normalized page text plus the
/// `:::kind` export form of parsed components.
pub fn render(segments: []const aside.Segment, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments) |segment| switch (segment) {
        .markdown => |markdown| {
            if (std.mem.trim(u8, markdown, " \t\r\n").len == 0) {
                try out.appendSlice(allocator, markdown);
            } else {
                const prepared = try demoteAtxH1ToH2(stripLeadingAtxH1(markdown), allocator);
                try out.appendSlice(allocator, prepared);
            }
        },
        .aside => |value| try out.appendSlice(allocator, try aside.formatRagDirective(value, allocator)),
        .details => |value| try out.appendSlice(allocator, try aside.formatDetailsRagDirective(value, allocator)),
    };
    return try out.toOwnedSlice(allocator);
}

test "leading H1 is stripped and later H1s demote to H2" {
    const gpa = std.testing.allocator;
    const stripped = stripLeadingAtxH1("# Title\n\nBody\n\n# Second\n");
    try std.testing.expectEqualStrings("\nBody\n\n# Second\n", stripped);
    const demoted = try demoteAtxH1ToH2(stripped, gpa);
    defer gpa.free(demoted);
    try std.testing.expectEqualStrings("\nBody\n\n## Second\n", demoted);
}
