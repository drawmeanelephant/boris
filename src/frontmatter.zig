//! Bounded frontmatter subset for Boris v0.1 metadata.
//!
//! Supported keys only:
//!   id, title, parent, status, tags
//!
//! Not YAML. Line-oriented `key: value` inside `---` fences.

const std = @import("std");
const diag = @import("diag.zig");
const page_mod = @import("page.zig");

/// Re-export PageDb promotion limits (single source of truth in `page.zig`).
pub const max_title_bytes = page_mod.max_title_bytes;
pub const max_entity_id_bytes = page_mod.max_entity_id_bytes;

pub const Status = enum {
    draft,
    published,
    archived,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn parse(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "draft")) return .draft;
        if (std.mem.eql(u8, s, "published")) return .published;
        if (std.mem.eql(u8, s, "archived")) return .archived;
        return null;
    }
};

pub const Meta = struct {
    /// Optional id override (canonical document id).
    id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    status: ?Status = null,
    /// Tags retained by caller's arena.
    tags: []const []const u8 = &.{},
    /// Byte offset of body start in source.
    body_offset: usize = 0,
    /// True if a frontmatter block was present (even if empty).
    has_frontmatter: bool = false,
};

const KeyFlags = struct {
    id: bool = false,
    title: bool = false,
    parent: bool = false,
    status: bool = false,
    tags: bool = false,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

/// Validate a canonical document id (path-like, no empties / `..` / whitespace / `\`).
/// Also enforces `max_entity_id_bytes` so oversized ids never enter the retain arena.
/// Delegates shape rules to `pathutil.validateEntityId` (single source of truth).
pub fn validateId(id: []const u8) bool {
    const pathutil = @import("pathutil.zig");
    return pathutil.validateEntityId(id);
}

fn parsePlainOrQuoted(raw: []const u8) ![]const u8 {
    const v = trimAscii(raw);
    if (v.len == 0) return error.EmptyValue;
    // Match product parser.zig parseScalarValue — reject YAML-looking forms.
    if (v[0] == '|' or v[0] == '>') return error.BlockScalar;
    if (v[0] == '[' or v[0] == '{') return error.FlowCollection;
    if (v[0] == '&' or v[0] == '*') return error.AnchorAlias;
    if (v[0] == '"') {
        if (v.len < 2 or v[v.len - 1] != '"') return error.BadQuote;
        const inner = v[1 .. v.len - 1];
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.BadQuote;
        if (inner.len == 0) return error.EmptyValue;
        return inner;
    }
    if (v[0] == '\'') return error.SingleQuote;
    return v;
}

/// Parse `tags: [a, b, "c"]` — only this bracket form is supported.
fn parseTagsList(retain: std.mem.Allocator, raw: []const u8) ![]const []const u8 {
    const v = trimAscii(raw);
    if (v.len < 2 or v[0] != '[' or v[v.len - 1] != ']') return error.BadTags;
    const inner = trimAscii(v[1 .. v.len - 1]);
    if (inner.len == 0) return &.{};

    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(retain);

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and isSpace(inner[i])) : (i += 1) {}
        if (i >= inner.len) break;

        var token: []const u8 = undefined;
        if (inner[i] == '"') {
            const start = i;
            i += 1;
            while (i < inner.len and inner[i] != '"') : (i += 1) {}
            if (i >= inner.len) return error.BadTags;
            i += 1; // closing "
            token = inner[start..i];
        } else {
            const start = i;
            while (i < inner.len and inner[i] != ',' and !isSpace(inner[i])) : (i += 1) {}
            token = inner[start..i];
        }

        const parsed = try parsePlainOrQuoted(token);
        try list.append(retain, try retain.dupe(u8, parsed));

        while (i < inner.len and isSpace(inner[i])) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != ',') return error.BadTags;
        i += 1;
    }

    return try list.toOwnedSlice(retain);
}

fn keyColumn(line: []const u8, key: []const u8) u32 {
    if (std.mem.indexOf(u8, line, key)) |idx| {
        return @intCast(idx + 1);
    }
    return 1;
}

fn pushDiag(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    diags: *std.ArrayList(diag.Diagnostic),
    source_path: []const u8,
    code: diag.Code,
    line: u32,
    column: u32,
    message: []const u8,
    remediation: []const u8,
) !void {
    try diags.append(list_gpa, .{
        .severity = .error_,
        .code = code,
        .message = try retain.dupe(u8, message),
        .remediation = try retain.dupe(u8, remediation),
        .source_path = source_path,
        .line = line,
        .column = column,
    });
}

/// Parse frontmatter from full file bytes. Aggregates diagnostics; never returns
/// an error for content issues (only OOM). `source_path` must outlive diags.
pub fn parse(
    source: []const u8,
    source_path: []const u8,
    retain: std.mem.Allocator,
    list_gpa: std.mem.Allocator,
    diags: *std.ArrayList(diag.Diagnostic),
) !Meta {
    var meta: Meta = .{};

    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        try pushDiag(list_gpa, retain, diags, source_path, .EINVALIDUTF8, 1, 1, "UTF-8 BOM is not allowed", "Save the file as UTF-8 without a BOM");
        return meta;
    }
    if (!std.unicode.utf8ValidateSlice(source)) {
        try pushDiag(list_gpa, retain, diags, source_path, .EINVALIDUTF8, 1, 1, "source is not valid UTF-8", "Re-encode the file as UTF-8");
        return meta;
    }

    // No frontmatter fence.
    if (!std.mem.startsWith(u8, source, "---")) {
        meta.body_offset = 0;
        return meta;
    }
    // Must be exactly --- as first line.
    var i: usize = 3;
    if (i < source.len and source[i] == '\r') i += 1;
    if (i >= source.len or source[i] != '\n') {
        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, 1, 1, "opening frontmatter fence must be a line consisting of exactly ---", "Start the file with --- on its own line");
        return meta;
    }
    i += 1;
    meta.has_frontmatter = true;

    var flags: KeyFlags = .{};
    var line_no: u32 = 2; // first content line inside FM

    while (i <= source.len) {
        const line_start = i;
        var line_end = i;
        while (line_end < source.len and source[line_end] != '\n') : (line_end += 1) {}
        var line = source[line_start..line_end];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (std.mem.eql(u8, line, "---")) {
            meta.body_offset = if (line_end < source.len) line_end + 1 else line_end;
            return meta;
        }

        const trimmed = trimAscii(line);
        if (trimmed.len == 0) {
            // advance
        } else if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            const key = trimAscii(trimmed[0..colon]);
            const raw_val = trimmed[colon + 1 ..];
            const col = keyColumn(line, key);

            if (key.len == 0) {
                try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "empty frontmatter key", "Use a supported key: id, title, parent, status, tags");
            } else if (std.mem.eql(u8, key, "id")) {
                if (flags.id) {
                    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "duplicate frontmatter key \"id\"", "Keep a single id field per document");
                } else {
                    flags.id = true;
                    const val = parsePlainOrQuoted(raw_val) catch |err| switch (err) {
                        error.EmptyValue => blk: {
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "id value must be a non-empty string", "Set id: to a canonical document id (e.g. guides/intro)");
                            break :blk null;
                        },
                        error.SingleQuote => blk: {
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "single-quoted values are not supported", "Use plain text or double quotes");
                            break :blk null;
                        },
                        error.BadQuote => blk: {
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "malformed double-quoted string", "Close the quote and avoid embedded raw quotes");
                            break :blk null;
                        },
                        error.BlockScalar, error.FlowCollection, error.AnchorAlias => blk: {
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "YAML block/flow/anchor forms are not supported for id", "Use a plain or double-quoted canonical document id");
                            break :blk null;
                        },
                    };
                    if (val) |v| {
                        if (v.len > max_entity_id_bytes) {
                            const msg = try std.fmt.allocPrint(retain, "id exceeds maximum length of {d} bytes (got {d})", .{ max_entity_id_bytes, v.len });
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, msg, "Shorten the id to at most 255 bytes");
                        } else if (!validateId(v)) {
                            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "id is not a valid canonical document id", "Use slash-separated segments without ., .., or whitespace");
                        } else {
                            // Bound checked: safe to retain into the long-lived arena.
                            meta.id = try retain.dupe(u8, v);
                        }
                    }
                }
            } else if (std.mem.eql(u8, key, "title")) {
                if (flags.title) {
                    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "duplicate frontmatter key \"title\"", "Keep a single title field per document");
                } else {
                    flags.title = true;
                    const val = parsePlainOrQuoted(raw_val) catch {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "title value must be a non-empty plain or double-quoted string", "Example: title: My Page");
                        line_no += 1;
                        if (line_end < source.len) i = line_end + 1 else break;
                        continue;
                    };
                    if (val.len > max_title_bytes) {
                        // Reject before dupe — oversized titles must not enter the retain arena.
                        const msg = try std.fmt.allocPrint(retain, "title exceeds maximum length of {d} bytes (got {d})", .{ max_title_bytes, val.len });
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, msg, "Shorten the title to at most 512 bytes");
                    } else {
                        meta.title = try retain.dupe(u8, val);
                    }
                }
            } else if (std.mem.eql(u8, key, "parent")) {
                if (flags.parent) {
                    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "duplicate frontmatter key \"parent\"", "Keep a single parent field per document");
                } else {
                    flags.parent = true;
                    const val = parsePlainOrQuoted(raw_val) catch {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "parent value must be a non-empty canonical document id", "Example: parent: guides/intro");
                        line_no += 1;
                        if (line_end < source.len) i = line_end + 1 else break;
                        continue;
                    };
                    if (val.len > max_entity_id_bytes) {
                        const msg = try std.fmt.allocPrint(retain, "parent exceeds maximum length of {d} bytes (got {d})", .{ max_entity_id_bytes, val.len });
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, msg, "Shorten the parent id to at most 255 bytes");
                    } else if (!validateId(val)) {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "parent is not a valid canonical document id", "Use the parent document id, not a file path or URL");
                    } else {
                        meta.parent = try retain.dupe(u8, val);
                    }
                }
            } else if (std.mem.eql(u8, key, "status")) {
                if (flags.status) {
                    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "duplicate frontmatter key \"status\"", "Keep a single status field per document");
                } else {
                    flags.status = true;
                    const val = parsePlainOrQuoted(raw_val) catch {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "status value is empty or malformed", "Use status: draft, published, or archived");
                        line_no += 1;
                        if (line_end < source.len) i = line_end + 1 else break;
                        continue;
                    };
                    if (Status.parse(val)) |st| {
                        meta.status = st;
                    } else {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "invalid status value", "Allowed status values: draft, published, archived");
                    }
                }
            } else if (std.mem.eql(u8, key, "tags")) {
                if (flags.tags) {
                    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "duplicate frontmatter key \"tags\"", "Keep a single tags list per document");
                } else {
                    flags.tags = true;
                    meta.tags = parseTagsList(retain, raw_val) catch {
                        try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, col, "tags must be a simple list like [a, b]", "Use tags: [tag1, tag2] with plain or double-quoted items");
                        meta.tags = &.{};
                        line_no += 1;
                        if (line_end < source.len) i = line_end + 1 else break;
                        continue;
                    };
                }
            } else {
                // Unknown / unsupported keys (including YAML-ish nesting attempts).
                const msg = try std.fmt.allocPrint(retain, "unsupported frontmatter key \"{s}\"", .{key});
                try diags.append(list_gpa, .{
                    .severity = .error_,
                    .code = .EFRONTMATTER,
                    .message = msg,
                    .remediation = try retain.dupe(u8, "Supported keys: id, title, parent, status, tags"),
                    .source_path = source_path,
                    .line = line_no,
                    .column = col,
                });
            }
        } else {
            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, line_no, 1, "malformed frontmatter line (expected key: value)", "Each non-empty frontmatter line must be key: value");
        }

        line_no += 1;
        if (line_end < source.len) {
            i = line_end + 1;
        } else {
            // EOF without closing fence.
            try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, 1, 1, "unclosed frontmatter: missing closing ---", "Add a closing --- line after the metadata fields");
            meta.body_offset = source.len;
            return meta;
        }
    }

    try pushDiag(list_gpa, retain, diags, source_path, .EFRONTMATTER, 1, 1, "unclosed frontmatter: missing closing ---", "Add a closing --- line after the metadata fields");
    meta.body_offset = source.len;
    return meta;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse title parent status tags" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const src =
        \\---
        \\title: Hello
        \\parent: guides/intro
        \\status: draft
        \\tags: [a, b]
        \\---
        \\# Body
        \\
    ;
    const meta = try parse(src, "x.md", retain, gpa, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqualStrings("Hello", meta.title.?);
    try std.testing.expectEqualStrings("guides/intro", meta.parent.?);
    try std.testing.expect(meta.status.? == .draft);
    try std.testing.expectEqual(@as(usize, 2), meta.tags.len);
    try std.testing.expectEqualStrings("a", meta.tags[0]);
    try std.testing.expectEqualStrings("b", meta.tags[1]);
}

// Non-product helper must match product closed set: no parentEntry alias.
test "parse rejects parentEntry as unknown key" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const src =
        \\---
        \\parentEntry: guides/intro
        \\---
        \\
    ;
    const meta = try parse(src, "legacy.md", retain, gpa, &diags);
    try std.testing.expect(meta.parent == null);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "parentEntry") != null);
}

test "parse rejects unknown key and continues" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const src =
        \\---
        \\title: T
        \\tags: nope
        \\parent: p
        \\---
        \\
    ;
    _ = try parse(src, "bad.md", retain, gpa, &diags);
    try std.testing.expect(diags.items.len >= 1);
    var saw_tags = false;
    for (diags.items) |d| {
        if (d.code == .EFRONTMATTER) saw_tags = true;
    }
    try std.testing.expect(saw_tags);
}

test "parse duplicate key" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const src =
        \\---
        \\title: A
        \\title: B
        \\---
        \\
    ;
    const meta = try parse(src, "d.md", retain, gpa, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EFRONTMATTER);
    try std.testing.expectEqualStrings("A", meta.title.?);
}

test "validateId" {
    try std.testing.expect(validateId("guides/intro"));
    try std.testing.expect(!validateId(""));
    try std.testing.expect(!validateId("a//b"));
    try std.testing.expect(!validateId("../x"));
    try std.testing.expect(!validateId("a b"));
    // Length bound: 255-byte id is ok; 256 is not.
    var id255: [max_entity_id_bytes]u8 = undefined;
    @memset(&id255, 'a');
    try std.testing.expect(validateId(&id255));
    var id256: [max_entity_id_bytes + 1]u8 = undefined;
    @memset(&id256, 'a');
    try std.testing.expect(!validateId(&id256));
}

test "parse rejects oversize title without retaining it" {
    // Feeds a multi-KB title into the frontmatter parser. Must emit a clear
    // diagnostic and leave meta.title null — never dupe the huge string into
    // the retain arena (PageDb / compile-run arena protection).
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const huge_len: usize = 10_000;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\ntitle: ");
    try src.appendNTimes(gpa, 'X', huge_len);
    try src.appendSlice(gpa, "\n---\n\n# body\n");

    const meta = try parse(src.items, "huge-title.md", retain, gpa, &diags);

    try std.testing.expect(meta.title == null);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "512") != null);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "10000") != null);
    // Retain arena holds only short diagnostic strings, never the 10KB title body.
    try std.testing.expect(arena.queryCapacity() < huge_len);
}

test "parse rejects oversize id without retaining it" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    const id_len = max_entity_id_bytes + 50;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\nid: ");
    try src.appendNTimes(gpa, 'e', id_len);
    try src.appendSlice(gpa, "\n---\n");

    const meta = try parse(src.items, "huge-id.md", retain, gpa, &diags);
    try std.testing.expect(meta.id == null);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, diags.items[0].message, "255") != null);
}

test "parse accepts title and id at exact length limits" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);

    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\ntitle: ");
    try src.appendNTimes(gpa, 'T', max_title_bytes);
    try src.appendSlice(gpa, "\nid: ");
    try src.appendNTimes(gpa, 'i', max_entity_id_bytes);
    try src.appendSlice(gpa, "\n---\n");

    const meta = try parse(src.items, "limits.md", retain, gpa, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqual(@as(usize, max_title_bytes), meta.title.?.len);
    try std.testing.expectEqual(@as(usize, max_entity_id_bytes), meta.id.?.len);
}
