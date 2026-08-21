//! Bounded frontmatter parser for boris-content-audit.
//!
//! Implements the small closed grammar from docs/contracts/frontmatter.md so
//! the audit tool stays standalone (no import of product compiler modules):
//!   - optional `---` fence at byte zero; fields are `key: value` one-liners
//!   - closed key set: id, title, parent, status, tags, relations,
//!     published_at, summary
//!   - tags:  `[a, b, "c"]`
//!   - relations: `[kind=target, ...]`
//!   - normative bounds: 1 MiB source, 64 KiB frontmatter block, 32 fields,
//!     title 512 bytes, summary 1,024 bytes, id/parent 255 bytes plus path
//!     shape, 32 tags, 64-byte tag tokens, closed status vocabulary,
//!     duplicate known-key rejection, BOM rejection, LF/CRLF fences.
//!
//! Rejected forms (never half-parsed): leading-indent nested mappings, YAML
//! sequence lines, single-quoted scalars, flow mappings/sequences on scalar
//! keys, block scalars, anchors/aliases.
//!
//! Unlike the product parser, unknown keys are NOT hard errors here: the
//! audit is read-only telemetry and must surface legacy/unknown fields as
//! reportable notes (e.g. old `mascotRef`, `relatedHaiku` fields) without
//! ever treating them as canonical truth. Their field syntax must still be
//! valid (no single-quoted, flow, or block forms). Structural violations that
//! make a record unidentifiable (duplicate id, malformed field line, unclosed
//! fence, invalid UTF-8) are reported as malformed records.

const std = @import("std");
const util = @import("util.zig");

pub const max_source_bytes: usize = 1_048_576; // 1 MiB, mirrors product bound
pub const max_frontmatter_bytes: usize = 64 * 1024; // inside fences, excluding fence lines
pub const max_frontmatter_fields: usize = 32; // non-blank field lines
pub const max_title_bytes: usize = 512;
pub const max_summary_bytes: usize = 1024;
pub const max_entity_id_bytes: usize = 255;
pub const max_tag_count: usize = 32;
pub const max_tag_bytes: usize = 64;
/// Must stay aligned with the product frontmatter contract's semantic
/// relation bound; this parser is a standalone audit projection, not a
/// separate authoring limit.
pub const max_relation_count: usize = 128;

pub const valid_statuses = [_][]const u8{ "draft", "published", "archived" };

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
};

pub const ParseIssue = union(enum) {
    invalid_utf8,
    bom_rejected,
    unclosed_frontmatter,
    malformed_field: []const u8,
    duplicate_key: []const u8,
    oversized,
    frontmatter_too_large,
    too_many_fields,
    too_many_tags,
    tag_too_long,
    summary_too_long,
    invalid_entity_id,
    invalid_status,
    unsupported_form,
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

/// Entity id / parent shape rules (docs/contracts/identity-and-paths.md):
/// never absolute, never `\`, never empty/`.`/`..` segments, and no
/// URL-significant `#`, `?`, or `%`. Length is checked separately.
fn validEntityIdShape(value: []const u8) bool {
    if (value.len == 0 or value.len > max_entity_id_bytes) return false;
    if (value[0] == '/') return false;
    for (value) |c| {
        if (c == '\\' or c == '#' or c == '?' or c == '%') return false;
    }
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0) return false;
        if (util.eql(part, ".") or util.eql(part, "..")) return false;
    }
    return true;
}

fn isValidStatus(value: []const u8) bool {
    for (valid_statuses) |s| {
        if (util.eql(s, value)) return true;
    }
    return false;
}

/// Split source into lines without allocating per line: allocate the line
/// array once.
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
    var count: usize = 0;
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
        if (token.len > max_tag_bytes) return error.TagTooLong;
        count += 1;
        if (count > max_tag_count) return error.TooManyTags;
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
    var count: usize = 0;
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
        count += 1;
        if (count > max_relation_count) return error.TooManyRelations;
        try out.append(gpa, .{ .kind = kind, .target = target });
    }
    return try out.toOwnedSlice(gpa);
}

/// Shape of a scalar (plain/dquoted) value after quote stripping. Callers
/// only pass non-empty values (empty is handled per-key), so there is no
/// empty case.
const ScalarForm = enum { ok, single_quoted, flow_or_block };

fn checkScalarForm(value: []const u8) ScalarForm {
    const first = value[0];
    if (first == '\'') return .single_quoted;
    // Flow mappings, flow sequences (on scalar keys), block scalars, anchors
    // and aliases are rejected forms — never half-parsed.
    if (first == '{' or first == '[' or first == '&' or first == '*' or first == '|' or first == '>') return .flow_or_block;
    return .ok;
}

/// Parse frontmatter + capture the body offset. Views reference `src`.
pub fn parse(gpa: std.mem.Allocator, src: []const u8) error{OutOfMemory}!ParseResult {
    // BOM policy: a leading UTF-8 BOM is rejected (never stripped, never
    // tolerated), matching the contract's EINVALIDUTF8 family.
    if (src.len >= 3 and src[0] == 0xEF and src[1] == 0xBB and src[2] == 0xBF) return .{ .err = .bom_rejected };
    // Size is checked before UTF-8 so an oversized file with an invalid tail
    // is classified `oversized` (and the full scan is skipped) rather than
    // misreported as `invalid_utf8`.
    if (src.len > max_source_bytes) return .{ .err = .oversized };
    if (!std.unicode.utf8ValidateSlice(src)) return .{ .err = .invalid_utf8 };

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
        index = 1;
        var closed = false;
        var fm_bytes: usize = 0;
        var field_count: usize = 0;
        // Known-key presence flags (bitmask) so duplicate detection covers
        // empty-list first occurrences too.
        var seen: u8 = 0;
        while (index < lines.len) : (index += 1) {
            const raw = lines[index];
            if (isFenceLine(raw)) {
                closed = true;
                index += 1;
                break;
            }
            const line = stripLineEnding(raw);
            if (isBlankLine(line)) continue;
            // Leading indent => nested mapping form (unsupported); a line
            // starting with `- ` is a YAML sequence (unsupported).
            if (line[0] == ' ' or line[0] == '\t') return .{ .err = .unsupported_form };
            if (line.len >= 2 and line[0] == '-' and line[1] == ' ') return .{ .err = .unsupported_form };
            field_count += 1;
            if (field_count > max_frontmatter_fields) return .{ .err = .too_many_fields };
            fm_bytes += line.len;
            if (fm_bytes > max_frontmatter_bytes) return .{ .err = .frontmatter_too_large };
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse {
                return .{ .err = .{ .malformed_field = line } };
            };
            const key = util.trim(line[0..colon]);
            var value = util.trim(line[colon + 1 ..]);
            if (key.len == 0) return .{ .err = .{ .malformed_field = line } };
            for (key) |c| {
                if (c == ' ' or c == '\t' or c == ':') return .{ .err = .{ .malformed_field = line } };
            }
            // dquoted form: strip surrounding quotes, reject embedded raw
            // quotes. A value that *starts* with a double quote but does not
            // end with one is malformed, never half-stripped.
            if (value.len > 0 and value[0] == '"') {
                if (value.len < 2 or value[value.len - 1] != '"') return .{ .err = .{ .malformed_field = line } };
                value = value[1 .. value.len - 1];
                for (value) |c| {
                    if (c == '"') return .{ .err = .{ .malformed_field = line } };
                }
            }

            // Scalar keys (and unknown keys) reject single-quoted and
            // flow/block forms; only tags/relations accept a bracketed list.
            // Empty values fall through to the per-key handlers.
            if (!util.eql(key, "tags") and !util.eql(key, "relations") and value.len > 0) {
                switch (checkScalarForm(value)) {
                    .ok => {},
                    .single_quoted, .flow_or_block => return .{ .err = .unsupported_form },
                }
            }
            // A double-quoted value with trailing content after the closing
            // quote is a malformed form (e.g. `title: "a" trailing`).
            if (value.len > 0 and value[value.len - 1] == '"' and value[0] != '"') return .{ .err = .{ .malformed_field = line } };

            const key_index: ?u3 = if (util.eql(key, "id")) 0 else if (util.eql(key, "title")) 1 else if (util.eql(key, "parent")) 2 else if (util.eql(key, "status")) 3 else if (util.eql(key, "tags")) 4 else if (util.eql(key, "relations")) 5 else if (util.eql(key, "published_at")) 6 else if (util.eql(key, "summary")) 7 else null;
            if (key_index) |ki| {
                const bit: u8 = @as(u8, 1) << @intCast(ki);
                if ((seen & bit) != 0) return .{ .err = .{ .duplicate_key = key } };
                seen |= bit;
            }

            if (util.eql(key, "id")) {
                if (!validEntityIdShape(value)) return .{ .err = .invalid_entity_id };
                parsed.id = value;
            } else if (util.eql(key, "title")) {
                if (value.len == 0 or value.len > max_title_bytes) return .{ .err = .{ .malformed_field = line } };
                parsed.title = value;
            } else if (util.eql(key, "parent")) {
                if (!validEntityIdShape(value)) return .{ .err = .invalid_entity_id };
                parsed.parent = value;
            } else if (util.eql(key, "status")) {
                if (!isValidStatus(value)) return .{ .err = .invalid_status };
                parsed.status = value;
            } else if (util.eql(key, "tags")) {
                const items = parseListItems(gpa, value) catch |e| return switch (e) {
                    error.TooManyTags => .{ .err = .too_many_tags },
                    error.TagTooLong => .{ .err = .tag_too_long },
                    else => .{ .err = .{ .malformed_field = line } },
                };
                for (items) |item| try tags.append(gpa, item);
            } else if (util.eql(key, "relations")) {
                const items = parseRelations(gpa, value) catch return .{ .err = .{ .malformed_field = line } };
                for (items) |item| try rels.append(gpa, item);
            } else if (util.eql(key, "published_at")) {
                parsed.published_at = value;
            } else if (util.eql(key, "summary")) {
                if (value.len == 0 or value.len > max_summary_bytes) return .{ .err = .summary_too_long };
                parsed.summary = value;
            } else {
                // Legacy/unknown key: report, never canonical; its field
                // syntax was already validated above. An empty value is a
                // malformed field.
                if (value.len == 0) return .{ .err = .{ .malformed_field = line } };
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

fn expectOk(gpa: std.mem.Allocator, src: []const u8) !void {
    switch (parse(gpa, src) catch @panic("oom")) {
        .ok => {},
        .err => |e| {
            std.debug.print("unexpected parse error: {s}\n", .{@tagName(e)});
            @panic("parse failed");
        },
    }
}

fn expectIssue(gpa: std.mem.Allocator, src: []const u8, tag: std.meta.Tag(ParseIssue)) !void {
    switch (parse(gpa, src) catch @panic("oom")) {
        .ok => @panic("expected parse issue"),
        .err => |issue| try std.testing.expectEqual(tag, std.meta.activeTag(issue)),
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

test "unknown legacy keys are reported not rejected (valid syntax only)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\---
        \\id: x
        \\relatedHaiku: haikus/HAI-100
        \\mascotRef: foo
        \\---
        \\
    ;
    const p = parseOk(a, src);
    try std.testing.expectEqual(p.unknown_keys.len, 2);
    try std.testing.expectEqualStrings("relatedHaiku", p.unknown_keys[0]);
    try std.testing.expectEqualStrings("mascotRef", p.unknown_keys[1]);
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
    try expectIssue(a, src, .duplicate_key);
}

test "duplicate tags with empty first list is a structural error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectIssue(a, "---\ntags: []\ntags: [a]\n---\n", .duplicate_key);
}

test "unclosed frontmatter is a structural error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\nid: a\n";
    try expectIssue(a, src, .unclosed_frontmatter);
}

test "invalid utf8 rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = [_]u8{ '-', '-', '-', '\n', 'a', 0xff, '\n' };
    try expectIssue(a, &src, .invalid_utf8);
}

test "oversized classification wins over invalid utf8 in the tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = try a.alloc(u8, max_source_bytes + 16);
    @memset(src, 'a');
    src[max_source_bytes + 4] = 0xff; // invalid byte beyond the size bound
    try expectIssue(a, src, .oversized);
}

test "leading BOM rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = [_]u8{ 0xEF, 0xBB, 0xBF, '-', '-', '-', '\n', 'i', 'd', ':', ' ', 'x', '\n', '-', '-', '-', '\n' };
    try expectIssue(a, &src, .bom_rejected);
}

test "crlf fences accepted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "---\r\nid: x\r\n---\r\nbody\r\n";
    const p = parseOk(a, src);
    try std.testing.expectEqualStrings("x", p.id.?);
}

// ---------------------------------------------------------------------------
// Contract conformance matrix
//
// Mirrors docs/contracts/frontmatter.md rule-by-rule so the audit parser
// cannot quietly become a second authoring dialect.
// ---------------------------------------------------------------------------

test "conformance matrix: accepted forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{
        // LF fences with plain values
        "---\nid: guides/intro\ntitle: Intro\nstatus: published\n---\nbody\n",
        // CRLF fences and fields
        "---\r\nid: guides/intro\r\ntitle: Intro\r\nstatus: published\r\n---\r\nbody\r\n",
        // Dquoted title with spaces and an embedded colon in the value
        "---\ntitle: \"Intro: part two\"\n---\n",
        // Plain value containing a colon (first colon separates key)
        "---\ntitle: Foo: Bar\n---\n",
        // Tags with plain and dquoted items
        "---\ntags: [a, \"b c\", d]\n---\n",
        // Relations
        "---\nrelations: [relates_to=poems/one, implements=x]\n---\n",
        // Empty frontmatter (open + immediate close)
        "---\n---\nbody\n",
        // No frontmatter at all
        "# Just a page\n",
        // summary may occur without published_at
        "---\nsummary: short note\n---\n",
        // Parent naming a collection is just a value; shape still valid
        "---\nparent: haikus\n---\n",
    };
    for (cases) |c| try expectOk(a, c);
}

test "conformance matrix: rejected forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // (source, expected issue tag)
    const cases = [_]struct { src: []const u8, tag: std.meta.Tag(ParseIssue) }{
        // Leading indentation => nested mapping form
        .{ .src = "---\n  id: x\n---\n", .tag = .unsupported_form },
        .{ .src = "---\n\tid: x\n---\n", .tag = .unsupported_form },
        // YAML sequence line
        .{ .src = "---\n- id: x\n---\n", .tag = .unsupported_form },
        // Single-quoted scalar
        .{ .src = "---\nid: 'x'\n---\n", .tag = .unsupported_form },
        .{ .src = "---\ntitle: 'single'\n---\n", .tag = .unsupported_form },
        // Flow mapping value
        .{ .src = "---\nid: {a: b}\n---\n", .tag = .unsupported_form },
        // Flow sequence on a scalar key
        .{ .src = "---\ntitle: [a]\n---\n", .tag = .unsupported_form },
        // Block scalar indicators
        .{ .src = "---\nsummary: |\n---\n", .tag = .unsupported_form },
        .{ .src = "---\nsummary: >\n---\n", .tag = .unsupported_form },
        // Dquoted value with trailing content (unbalanced quotes)
        .{ .src = "---\ntitle: \"a\" trailing\n---\n", .tag = .malformed_field },
        .{ .src = "---\ntitle: trailing\"\n---\n", .tag = .malformed_field },
        // Anchor / alias
        .{ .src = "---\ntitle: &x\n---\n", .tag = .unsupported_form },
        .{ .src = "---\nparent: *x\n---\n", .tag = .unsupported_form },
        // Unknown key with flow-sequence syntax is still rejected
        .{ .src = "---\nrelatedHaiku: [a]\n---\n", .tag = .unsupported_form },
        // Duplicate keys
        .{ .src = "---\nid: a\nid: b\n---\n", .tag = .duplicate_key },
        .{ .src = "---\ntitle: a\ntitle: b\n---\n", .tag = .duplicate_key },
        .{ .src = "---\nstatus: draft\nstatus: published\n---\n", .tag = .duplicate_key },
        // Invalid status value (exact spellings only)
        .{ .src = "---\nstatus: live\n---\n", .tag = .invalid_status },
        .{ .src = "---\nstatus: Draft\n---\n", .tag = .invalid_status },
        // Invalid entity id shapes
        .{ .src = "---\nid: /abs\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\nid: a/../b\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\nid: a//b\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\nid: a#b\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\nid: a\\b\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\nparent: guides/./intro\n---\n", .tag = .invalid_entity_id },
        // Empty value on a required scalar key
        .{ .src = "---\nid:\n---\n", .tag = .invalid_entity_id },
        .{ .src = "---\ntitle:\n---\n", .tag = .malformed_field },
        // Oversized id
        .{ .src = "---\nid: " ++ ("x" ** (max_entity_id_bytes + 1)) ++ "\n---\n", .tag = .invalid_entity_id },
        // Oversized title
        .{ .src = "---\ntitle: " ++ ("x" ** (max_title_bytes + 1)) ++ "\n---\n", .tag = .malformed_field },
        // Oversized summary
        .{ .src = "---\nsummary: " ++ ("x" ** (max_summary_bytes + 1)) ++ "\n---\n", .tag = .summary_too_long },
    };
    for (cases) |c| try expectIssue(a, c.src, c.tag);
}

test "conformance matrix: list limits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Too many tags (33 items).
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "---\ntags: [");
        var i: usize = 0;
        while (i <= max_tag_count) : (i += 1) {
            if (i > 0) try src.appendSlice(a, ", ");
            try src.appendSlice(a, "t");
        }
        try src.appendSlice(a, "]\n---\n");
        try expectIssue(a, src.items, .too_many_tags);
    }
    // Tag token longer than 64 bytes.
    {
        const long = "x" ** (max_tag_bytes + 1);
        const src = try std.fmt.allocPrint(a, "---\ntags: [{s}]\n---\n", .{long});
        try expectIssue(a, src, .tag_too_long);
    }
    // Too many fields (33 non-blank field lines).
    {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "---\n");
        var i: usize = 0;
        while (i <= max_frontmatter_fields) : (i += 1) {
            try src.appendSlice(a, "legacykey");
            try src.print(a, "{d}", .{i});
            try src.appendSlice(a, ": v\n");
        }
        try src.appendSlice(a, "---\n");
        try expectIssue(a, src.items, .too_many_fields);
    }
    // Frontmatter block larger than 64 KiB (single field, so the field-count
    // and title bounds cannot trip first).
    {
        const big = "x" ** (max_frontmatter_bytes + 1);
        const src = try std.fmt.allocPrint(a, "---\nlegacyfield: {s}\n---\n", .{big});
        try expectIssue(a, src, .frontmatter_too_large);
    }
}

test "semantic relation limit matches the product contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for ([_]struct { count: usize, accepted: bool }{
        .{ .count = max_relation_count, .accepted = true },
        .{ .count = max_relation_count + 1, .accepted = false },
    }) |case| {
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(a);
        try src.appendSlice(a, "---\nrelations: [");
        for (0..case.count) |i| {
            if (i > 0) try src.appendSlice(a, ", ");
            try src.print(a, "relates_to=poetry/{d}", .{i});
        }
        try src.appendSlice(a, "]\n---\n");

        switch (try parse(a, src.items)) {
            .ok => |parsed| {
                try std.testing.expect(case.accepted);
                try std.testing.expectEqual(case.count, parsed.relations.len);
            },
            .err => |issue| {
                try std.testing.expect(!case.accepted);
                try std.testing.expectEqual(ParseIssue.malformed_field, std.meta.activeTag(issue));
            },
        }
    }
}

test "source larger than max_source_bytes is oversized before any parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Build a source slice of exactly max_source_bytes + 1. The parser must
    // reject it as oversized without scanning the whole body.
    const src = try a.alloc(u8, max_source_bytes + 1);
    @memset(src, 'a');
    const result = try parse(a, src);
    try std.testing.expect(result == .err);
    try std.testing.expect(result.err == .oversized);
    // Exactly at the bound parses (as a body-only file, not oversized).
    const boundary = try a.alloc(u8, max_source_bytes);
    @memset(boundary, 'b');
    const at_bound = try parse(a, boundary);
    try std.testing.expect(at_bound == .ok);
}
