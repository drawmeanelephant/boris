//! Bounded frontmatter parser for boris-content-audit.
//!
//! Implements the small closed grammar from docs/contracts/frontmatter.md so
//! the audit tool stays standalone (no import of product compiler modules):
//!   - optional `---` fence at byte zero; fields are `key: value` one-liners
//!   - closed key set: id, title, parent, status, tags, relations,
//!     published_at, summary
//!   - tags:  `[a, b, "c"]`
//!   - relations: `[kind=target, ...]`
//!
//! Unlike the product parser, unknown keys are NOT hard errors here: the
//! audit is read-only telemetry and must surface legacy/unknown fields as
//! reportable notes (e.g. old `mascotRef`, `relatedHaiku` fields) without
//! ever treating them as canonical truth. Structural violations that make a
//! record unidentifiable (duplicate id, malformed field line, unclosed
//! fence, invalid UTF-8) are reported as malformed records.

const std = @import("std");
const util = @import("util.zig");

pub const max_source_bytes: usize = 1_048_576; // 1 MiB, mirrors product bound
pub const max_title_bytes: usize = 512;
pub const max_entity_id_bytes: usize = 255;

pub const Relation = struct {
    kind: []const u8,
    target: []const u8,
};

pub const Parsed = struct {
    /// Present iff the file opened with a complete `---` fence.
    has_frontmatter: bool,
    /// View slices into the source buffer (no copies).
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    relations: []const Relation = &.{},
    published_at: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    /// Unknown/legacy keys seen (never canonical).
    unknown_keys: []const []const u8 = &.{},
    /// Byte offset where the body begins (0 when no frontmatter).
    body_offset: usize = 0,
    /// Line number of the first field line (for diagnostics; 1-based).
    first_field_line: usize = 0,
};

pub const ParseIssue = union(enum) {
    invalid_utf8,
    unclosed_frontmatter,
    malformed_field: []const u8,
    duplicate_key: []const u8,
    oversized,
};

pub const ParseResult = union(enum) {
    ok: Parsed,
    err: ParseIssue,
};

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return false;
    }
    return true;
}

fn stripLineEnding(line: []const u8) []const u8 {
    if (line.len >= 2 and line[line.len - 2] == '\r' and line[line.len - 1] == '\n') return line[0 .. line.len - 2];
    if (line.len >= 1 and line[line.len - 1] == '\n') return line[0 .. line.len - 1];
    if (line.len >= 1 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

fn isFenceLine(line: []const u8) bool {
    // Exactly `---` at column zero (optional trailing \r).
    if (line.len == 3 and util.eql(line, "---")) return true;
    if (line.len == 4 and util.eql(line[0..3], "---") and line[3] == '\r') return true;
    return false;
}

/// Split source into lines without allocating: caller iterates over the
/// returned slice-of-slices? We allocate the line array once.
fn splitLines(gpa: std.mem.Allocator, src: []const u8) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    errdefer lines.deinit(gpa);
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        try lines.append(gpa, line);
    }
    return try lines.toOwnedSlice(gpa);
}

fn parseListItems(gpa: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(gpa);
    var rest = value;
    // Expect `[ ... ]`
    if (rest.len < 2 or rest[0] != '[') return error.MalformedList;
    if (rest[rest.len - 1] != ']') return error.MalformedList;
    rest = rest[1 .. rest.len - 1];
    var parts = std.mem.splitScalar(u8, rest, ',');
    while (parts.next()) |raw| {
        const item = util.trim(raw);
        if (item.len == 0) continue;
        // strip surrounding double quotes if present
        var token = item;
        if (token.len >= 2 and token[0] == '"' and token[token.len - 1] == '"') {
            token = token[1 .. token.len - 1];
            for (token) |c| {
                if (c == '"') return error.MalformedList;
            }
        } else {
            for (token) |c| {
                if (c == '"' or c == '[' or c == ']') return error.MalformedList;
            }
        }
        if (token.len == 0) return error.MalformedList;
        try out.append(gpa, token);
    }
    return try out.toOwnedSlice(gpa);
}

fn parseRelations(gpa: std.mem.Allocator, value: []const u8) ![]const Relation {
    var out: std.ArrayList(Relation) = .empty;
    errdefer out.deinit(gpa);
    var rest = value;
    if (rest.len < 2 or rest[0] != '[') return error.MalformedList;
    if (rest[rest.len - 1] != ']') return error.MalformedList;
    rest = rest[1 .. rest.len - 1];
    var parts = std.mem.splitScalar(u8, rest, ',');
    while (parts.next()) |raw| {
        const item = util.trim(raw);
        if (item.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, item, '=') orelse return error.MalformedList;
        const kind = util.trim(item[0..eq]);
        const target = util.trim(item[eq + 1 ..]);
        if (kind.len == 0 or target.len == 0) return error.MalformedList;
        for (kind) |c| {
            if (c == '"' or c == '[' or c == ']' or c == '=') return error.MalformedList;
        }
        for (target) |c| {
            if (c == '"' or c == '[' or c == ']' or c == '=') return error.MalformedList;
        }
        try out.append(gpa, .{ .kind = kind, .target = target });
    }
    return try out.toOwnedSlice(gpa);
}

/// Parse frontmatter + capture the body offset. Views reference `src`.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) error{OutOfMemory}!ParseResult {
    if (!std.unicode.utf8ValidateSlice(src)) return .{ .err = .invalid_utf8 };
    if (src.len > max_source_bytes) return .{ .err = .oversized };

    const lines = splitLines(gpa, src) catch return error.OutOfMemory;
    defer gpa.free(lines);

    var parsed: Parsed = .{ .has_frontmatter = false };
    var unknown: std.ArrayList([]const u8) = .empty;
    var tags: std.ArrayList([]const u8) = .empty;
    var rels: std.ArrayList(Relation) = .empty;

    // Optional frontmatter: opening fence must be the first complete line.
    var index: usize = 0;
    if (lines.len > 0 and isFenceLine(lines[0])) {
        parsed.has_frontmatter = true;
        parsed.first_field_line = 2;
        index = 1;
        var closed = false;
        while (index < lines.len) : (index += 1) {
            const raw = lines[index];
            if (isFenceLine(raw)) {
                closed = true;
                index += 1;
                break;
            }
            const line = stripLineEnding(raw);
            if (isBlankLine(line)) continue;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                return .{ .err = .{ .malformed_field = line } };
            };
            const key = util.trim(line[0..colon]);
            var value = line[colon + 1 ..];
            // value: optional single space/tab
            value = util.trim(value);
            // dquoted form: strip surrounding quotes, reject embedded raw quotes
            if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
                value = value[1 .. value.len - 1];
                for (value) |c| {
                    if (c == '"') return .{ .err = .{ .malformed_field = line } };
                }
            }
            if (key.len == 0) return .{ .err = .{ .malformed_field = line } };
            for (key) |c| {
                if (c == ' ' or c == '\t' or c == ':') return .{ .err = .{ .malformed_field = line } };
            }
            if (util.eql(key, "id")) {
                if (parsed.id != null) return .{ .err = .{ .duplicate_key = key } };
                if (value.len == 0 or value.len > max_entity_id_bytes) return .{ .err = .{ .malformed_field = line } };
                parsed.id = value;
            } else if (util.eql(key, "title")) {
                if (parsed.title != null) return .{ .err = .{ .duplicate_key = key } };
                if (value.len == 0 or value.len > max_title_bytes) return .{ .err = .{ .malformed_field = line } };
                parsed.title = value;
            } else if (util.eql(key, "parent")) {
                if (parsed.parent != null) return .{ .err = .{ .duplicate_key = key } };
                if (value.len == 0 or value.len > max_entity_id_bytes) return .{ .err = .{ .malformed_field = line } };
                parsed.parent = value;
            } else if (util.eql(key, "status")) {
                if (parsed.status != null) return .{ .err = .{ .duplicate_key = key } };
                parsed.status = value;
            } else if (util.eql(key, "tags")) {
                if (parsed.tags.len != 0) return .{ .err = .{ .duplicate_key = key } };
                const items = parseListItems(gpa, value) catch return .{ .err = .{ .malformed_field = line } };
                for (items) |item| try tags.append(gpa, item);
            } else if (util.eql(key, "relations")) {
                if (parsed.relations.len != 0) return .{ .err = .{ .duplicate_key = key } };
                const items = parseRelations(gpa, value) catch return .{ .err = .{ .malformed_field = line } };
                for (items) |item| try rels.append(gpa, item);
            } else if (util.eql(key, "published_at")) {
                if (parsed.published_at != null) return .{ .err = .{ .duplicate_key = key } };
                parsed.published_at = value;
            } else if (util.eql(key, "summary")) {
                if (parsed.summary != null) return .{ .err = .{ .duplicate_key = key } };
                parsed.summary = value;
            } else {
                // Legacy/unknown key: report, never canonical.
                try unknown.append(gpa, key);
            }
        }
        if (!closed) return .{ .err = .unclosed_frontmatter };
        if (index <= lines.len) {
            // body starts at the byte after the closing fence line's newline
            var body_offset: usize = 0;
            var n: usize = 0;
            while (n < index) : (n += 1) {
                body_offset += lines[n].len + 1;
            }
            // The closing fence may be the final line with no trailing newline
            // (body_offset counts one byte per line regardless); clamp so the
            // body slice never exceeds the source buffer.
            if (body_offset > src.len) body_offset = src.len;
            parsed.body_offset = body_offset;
        }
    } else {
        parsed.body_offset = 0;
    }
    parsed.tags = try tags.toOwnedSlice(gpa);
    parsed.relations = try rels.toOwnedSlice(gpa);
    parsed.unknown_keys = try unknown.toOwnedSlice(gpa);
    return .{ .ok = parsed };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(gpa: std.mem.Allocator, src: []const u8) Parsed {
    switch (parse(gpa, src) catch @panic("oom")) {
        .ok => |p| return p,
        .err => |e| {
            std.debug.print("unexpected parse error: {s}\n", .{@tagName(e)});
            @panic("parse failed");
        },
    }
}

test "frontmatter basic fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\id: guides/intro
        \\title: "Intro"
        \\parent: guides
        \\status: published
        \\tags: [a, "b c"]
        \\relations: [relates_to=poems/one]
        \\---
        \\# Body
        \\
    ;
    const p = parseOk(a, src);
    try std.testing.expectEqualStrings("guides/intro", p.id.?);
    try std.testing.expectEqualStrings("Intro", p.title.?);
    try std.testing.expectEqualStrings("guides", p.parent.?);
    try std.testing.expectEqualStrings("published", p.status.?);
    try std.testing.expectEqual(p.tags.len, 2);
    try std.testing.expectEqualStrings("a", p.tags[0]);
    try std.testing.expectEqualStrings("b c", p.tags[1]);
    try std.testing.expectEqual(p.relations.len, 1);
    try std.testing.expectEqualStrings("relates_to", p.relations[0].kind);
    try std.testing.expectEqualStrings("poems/one", p.relations[0].target);
    try std.testing.expectEqual(p.unknown_keys.len, 0);
}

test "no frontmatter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = parseOk(a, "# Just a page\n");
    try std.testing.expect(!p.has_frontmatter);
    try std.testing.expectEqual(p.body_offset, 0);
}

test "unknown legacy keys are reported not rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\id: x
        \\relatedHaiku: [a]
        \\mascotRef: foo
        \\---
        \\
    ;
    const p = parseOk(a, src);
    try std.testing.expectEqual(p.unknown_keys.len, 2);
    try std.testing.expectEqualStrings("relatedHaiku", p.unknown_keys[0]);
}

test "duplicate id is a structural error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\id: a
        \\id: b
        \\---
        \\
    ;
    switch (parse(a, src) catch @panic("oom")) {
        .err => |e| try std.testing.expect(e == .duplicate_key),
        .ok => @panic("expected error"),
    }
}

test "unclosed frontmatter is a structural error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\nid: a\n";
    switch (parse(a, src) catch @panic("oom")) {
        .err => |e| try std.testing.expect(e == .unclosed_frontmatter),
        .ok => @panic("expected error"),
    }
}

test "invalid utf8 rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = [_]u8{ '-', '-', '-', '\n', 'a', 0xff, '\n' };
    switch (parse(a, &src) catch @panic("oom")) {
        .err => |e| try std.testing.expect(e == .invalid_utf8),
        .ok => @panic("expected error"),
    }
}

test "crlf fences accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\r\nid: x\r\n---\r\nbody\r\n";
    const p = parseOk(a, src);
    try std.testing.expectEqualStrings("x", p.id.?);
}
