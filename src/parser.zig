//! Strict, bounded frontmatter parser and Markdown body splitter (milestone 5).
//!
//! ## What this is
//!
//! A **deliberately closed, line-oriented** metadata grammar plus a body slice.
//! It is **not** YAML, not a YAML subset, not a general config language, and
//! not a component / Aside / Apex tokenizer.
//!
//! ## Ownership
//!
//! On success, every string field on `ParsedDocument` / `FrontmatterView` is a
//! **view into the caller-supplied `source` buffer** (or a closed enum for
//! `status`). The parser does not allocate and does not copy field values.
//! Callers that need durable storage (PageDb, long-lived arenas) must **dupe**
//! before releasing `source`.
//!
//! ## Encoding / line endings
//!
//! - Full source must be valid UTF-8 → `EINVALIDUTF8`.
//! - A leading UTF-8 BOM (`EF BB BF`) is **rejected** (never stripped) →
//!   `EINVALIDUTF8`.
//! - **LF** and **CRLF** line endings are accepted for fence and field lines.
//! - Isolated CR is not a line break (it remains part of line content).
//! - Body bytes after the closing fence are returned **verbatim** (no BOM
//!   strip; no line-ending rewrite).
//!
//! ## Title when absent
//!
//! `title` is `null`. v0.1 does not derive a title from the filename or from
//! Markdown headings (path-derived id is a later pipeline concern).
//!
//! ## Implementation shape
//!
//! Single forward iterative scan. **No recursion.**

const std = @import("std");
const identity = @import("identity.zig");
const page_mod = @import("page.zig");

pub const max_title_bytes = page_mod.max_title_bytes;
pub const max_entity_id_bytes = page_mod.max_entity_id_bytes;
pub const max_tag_bytes = page_mod.max_tag_bytes;
pub const max_tag_count = page_mod.max_tag_count;
pub const max_source_bytes = page_mod.max_source_bytes;
pub const max_frontmatter_bytes = page_mod.max_frontmatter_bytes;
pub const max_frontmatter_fields = page_mod.max_frontmatter_fields;

pub const Status = page_mod.Status;
pub const FrontmatterView = page_mod.FrontmatterView;

// ---------------------------------------------------------------------------
// Diagnostics (contract categories — docs/contracts/diagnostics.md)
// ---------------------------------------------------------------------------

/// Stable machine-readable categories used by this parser.
pub const Category = enum {
    /// Unclosed fence, bad line, unknown/duplicate key, unsupported form,
    /// empty/oversize values, invalid status/tags, source/frontmatter limits.
    EFRONTMATTER,
    /// Invalid UTF-8 or leading UTF-8 BOM.
    EINVALIDUTF8,
    /// Frontmatter `id` fails entity-id shape rules.
    EINVALIDPATH,

    pub fn name(self: Category) []const u8 {
        return @tagName(self);
    }
};

pub const Diagnostic = struct {
    category: Category,
    /// 1-based line in source; 1 when N/A.
    line: u32 = 1,
    /// 1-based byte column within the line; 1 when N/A.
    column: u32 = 1,
    /// Static human message (never allocator-owned).
    message: []const u8,
};

// ---------------------------------------------------------------------------
// Result model
// ---------------------------------------------------------------------------

/// Successful or partial parse product. String fields are source views.
pub const ParsedDocument = struct {
    /// True when an opening `---` fence was recognized at file start.
    has_frontmatter: bool = false,
    /// Body slice into `source` (after closing fence, or entire file if none).
    body: []const u8 = "",
    /// Byte offset of `body` within `source`.
    body_offset: usize = 0,
    /// Parsed fields (source views). Defaults apply when keys are absent.
    meta: FrontmatterView = .{},
};

pub const ParseResult = struct {
    doc: ParsedDocument = .{},
    /// Set on failure. Tests must assert `diagnostic.?.category`.
    diagnostic: ?Diagnostic = null,

    pub fn isOk(self: ParseResult) bool {
        return self.diagnostic == null;
    }

    pub fn category(self: ParseResult) ?Category {
        if (self.diagnostic) |d| return d.category;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Line helpers (iterative)
// ---------------------------------------------------------------------------

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Read one physical line from `source` starting at `start`.
/// Returns `(content_without_trailing_CR, next_offset, saw_newline)`.
fn readPhysicalLine(source: []const u8, start: usize) struct { []const u8, usize, bool } {
    var end = start;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    var line = source[start..end];
    if (line.len > 0 and line[line.len - 1] == '\r') {
        line = line[0 .. line.len - 1];
    }
    if (end < source.len and source[end] == '\n') {
        return .{ line, end + 1, true };
    }
    return .{ line, end, false };
}

fn keyColumnInLine(line: []const u8, key: []const u8) u32 {
    if (std.mem.indexOf(u8, line, key)) |idx| {
        return @intCast(idx + 1);
    }
    return 1;
}

fn fail(category: Category, line: u32, column: u32, message: []const u8) ParseResult {
    return .{
        .diagnostic = .{
            .category = category,
            .line = line,
            .column = column,
            .message = message,
        },
    };
}

fn utf8BomAtStart(source: []const u8) bool {
    return source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF;
}

// ---------------------------------------------------------------------------
// Scalar / tags value parsing (bounded — not YAML)
// ---------------------------------------------------------------------------

const ScalarError = error{
    EmptyValue,
    SingleQuote,
    BadQuote,
    BlockScalar,
    FlowCollection,
    AnchorAlias,
};

/// Parse a one-line scalar. Returned slice is into `raw` (hence into source).
fn parseScalarValue(raw: []const u8) ScalarError![]const u8 {
    const v = trimAscii(raw);
    if (v.len == 0) return error.EmptyValue;

    if (v[0] == '|' or v[0] == '>') return error.BlockScalar;
    if (v[0] == '[' or v[0] == '{') return error.FlowCollection;
    if (v[0] == '&' or v[0] == '*') return error.AnchorAlias;
    if (v[0] == '\'') return error.SingleQuote;

    if (v[0] == '"') {
        if (v.len < 2 or v[v.len - 1] != '"') return error.BadQuote;
        const inner = v[1 .. v.len - 1];
        // No escape sequences; embedded raw `"` is illegal.
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.BadQuote;
        if (inner.len == 0) return error.EmptyValue;
        return inner;
    }

    return v;
}

const TagsError = error{
    BadTags,
    TooManyTags,
    TagTooLong,
};

/// Parse `tags: [a, b, "c"]` only. Tag slices are into `raw` / source.
fn parseTagsList(raw: []const u8, out: *[max_tag_count][]const u8) TagsError!usize {
    const v = trimAscii(raw);
    if (v.len < 2 or v[0] != '[' or v[v.len - 1] != ']') return error.BadTags;
    const inner = trimAscii(v[1 .. v.len - 1]);
    if (inner.len == 0) return 0;

    var count: usize = 0;
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
            i += 1;
            token = inner[start..i];
        } else if (inner[i] == '\'') {
            return error.BadTags;
        } else {
            const start = i;
            while (i < inner.len and inner[i] != ',' and !isSpace(inner[i])) : (i += 1) {}
            token = inner[start..i];
        }

        const parsed = parseScalarValue(token) catch return error.BadTags;
        if (parsed.len > max_tag_bytes) return error.TagTooLong;
        if (count >= max_tag_count) return error.TooManyTags;
        out[count] = parsed;
        count += 1;

        while (i < inner.len and isSpace(inner[i])) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != ',') return error.BadTags;
        i += 1;
    }
    return count;
}

// ---------------------------------------------------------------------------
// Public entry
// ---------------------------------------------------------------------------

/// Parse `source` as optional frontmatter + body.
///
/// All returned string slices are views into `source`. No allocator is used.
/// Fail-fast: the first diagnostic is returned; field storage is left partial.
pub fn parse(source: []const u8) ParseResult {
    var doc: ParsedDocument = .{
        .body = source,
        .body_offset = 0,
    };

    // --- bounds / encoding gate -------------------------------------------
    if (source.len > max_source_bytes) {
        return fail(.EFRONTMATTER, 1, 1, "source exceeds maximum accepted size");
    }
    if (utf8BomAtStart(source)) {
        return fail(.EINVALIDUTF8, 1, 1, "UTF-8 BOM is not allowed");
    }
    if (source.len > 0 and !std.unicode.utf8ValidateSlice(source)) {
        return fail(.EINVALIDUTF8, 1, 1, "source is not valid UTF-8");
    }

    // --- optional frontmatter ---------------------------------------------
    if (source.len == 0) {
        return .{ .doc = doc };
    }

    const first = readPhysicalLine(source, 0);
    if (!std.mem.eql(u8, first[0], "---")) {
        // No opening fence at column zero → entire file is body.
        return .{ .doc = doc };
    }

    // Opening fence present. A file that is only `---` (no newline) is unclosed.
    if (!first[2]) {
        return fail(.EFRONTMATTER, 1, 1, "unclosed frontmatter: missing closing ---");
    }

    doc.has_frontmatter = true;
    const fm_content_start = first[1];

    // Find closing fence: a complete line that is exactly `---` at column zero.
    var close_line_start: ?usize = null;
    var close_after: usize = 0;
    var scan = fm_content_start;
    while (scan <= source.len) {
        if (scan >= source.len) break;
        const pl = readPhysicalLine(source, scan);
        if (std.mem.eql(u8, pl[0], "---")) {
            close_line_start = scan;
            close_after = pl[1]; // byte after the closing fence's newline (or EOF)
            break;
        }
        if (!pl[2]) break; // last line without newline — cannot be a close fence line with body after
        scan = pl[1];
    }

    if (close_line_start == null) {
        return fail(.EFRONTMATTER, 1, 1, "unclosed frontmatter: missing closing ---");
    }

    const fm_block = source[fm_content_start..close_line_start.?];
    if (fm_block.len > max_frontmatter_bytes) {
        return fail(.EFRONTMATTER, 1, 1, "frontmatter exceeds maximum size");
    }

    // Body is everything after the closing fence line (including its newline).
    doc.body_offset = close_after;
    doc.body = source[close_after..];

    // --- field lines ------------------------------------------------------
    var saw_id = false;
    var saw_title = false;
    var saw_parent = false;
    var saw_status = false;
    var saw_tags = false;
    var field_count: usize = 0;

    var line_no: u32 = 2; // first field line is after opening ---
    var fline_start: usize = 0;
    while (fline_start <= fm_block.len) {
        if (fline_start >= fm_block.len) break;
        const pl = readPhysicalLine(fm_block, fline_start);
        const raw_line = pl[0];

        if (trimAscii(raw_line).len == 0) {
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        // Nested mapping / indent form.
        if (raw_line[0] == ' ' or raw_line[0] == '\t') {
            return fail(.EFRONTMATTER, line_no, 1, "indented frontmatter lines are not supported (no nested mappings)");
        }

        // YAML sequence item form.
        if (raw_line.len >= 2 and raw_line[0] == '-' and (raw_line[1] == ' ' or raw_line[1] == '\t')) {
            return fail(.EFRONTMATTER, line_no, 1, "YAML sequences are not supported in frontmatter");
        }

        // Anchors / aliases as whole-line forms.
        if (raw_line[0] == '&' or raw_line[0] == '*') {
            return fail(.EFRONTMATTER, line_no, 1, "YAML anchors and aliases are not supported");
        }

        const colon = std.mem.indexOfScalar(u8, raw_line, ':') orelse {
            return fail(.EFRONTMATTER, line_no, 1, "malformed frontmatter line (expected key: value)");
        };

        const key = trimAscii(raw_line[0..colon]);
        const raw_val = raw_line[colon + 1 ..];
        const col = keyColumnInLine(raw_line, key);

        if (key.len == 0) {
            return fail(.EFRONTMATTER, line_no, 1, "empty frontmatter key");
        }

        field_count += 1;
        if (field_count > max_frontmatter_fields) {
            return fail(.EFRONTMATTER, line_no, col, "frontmatter exceeds maximum field count");
        }

        // `tags` is the only deliberately supported non-scalar form.
        if (std.mem.eql(u8, key, "tags")) {
            if (saw_tags) {
                return fail(.EFRONTMATTER, line_no, col, "duplicate frontmatter key \"tags\"");
            }
            saw_tags = true;
            const n = parseTagsList(raw_val, &doc.meta.tags) catch |err| {
                return switch (err) {
                    error.TooManyTags => fail(.EFRONTMATTER, line_no, col, "tags exceeds maximum tag count"),
                    error.TagTooLong => fail(.EFRONTMATTER, line_no, col, "tag exceeds maximum length"),
                    error.BadTags => fail(.EFRONTMATTER, line_no, col, "tags must be a simple list like [a, b] with plain or double-quoted items"),
                };
            };
            doc.meta.tag_count = n;
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        const value = parseScalarValue(raw_val) catch |err| {
            return switch (err) {
                error.EmptyValue => fail(.EFRONTMATTER, line_no, col, "frontmatter value must be a non-empty plain or double-quoted string"),
                error.SingleQuote => fail(.EFRONTMATTER, line_no, col, "single-quoted values are not supported; use plain text or double quotes"),
                error.BadQuote => fail(.EFRONTMATTER, line_no, col, "malformed double-quoted string (no escapes; no embedded raw quotes)"),
                error.BlockScalar => fail(.EFRONTMATTER, line_no, col, "YAML block scalars (| and >) are not supported"),
                error.FlowCollection => fail(.EFRONTMATTER, line_no, col, "YAML flow sequences/mappings ([ ] { }) are not supported on this key"),
                error.AnchorAlias => fail(.EFRONTMATTER, line_no, col, "YAML anchors and aliases are not supported"),
            };
        };

        if (std.mem.eql(u8, key, "title")) {
            if (saw_title) {
                return fail(.EFRONTMATTER, line_no, col, "duplicate frontmatter key \"title\"");
            }
            saw_title = true;
            if (value.len > max_title_bytes) {
                return fail(.EFRONTMATTER, line_no, col, "title exceeds maximum length");
            }
            doc.meta.title = value;
        } else if (std.mem.eql(u8, key, "id")) {
            if (saw_id) {
                return fail(.EFRONTMATTER, line_no, col, "duplicate frontmatter key \"id\"");
            }
            saw_id = true;
            if (value.len > max_entity_id_bytes) {
                return fail(.EFRONTMATTER, line_no, col, "id exceeds maximum length");
            }
            if (!identity.validateEntityId(value)) {
                return fail(.EINVALIDPATH, line_no, col, "id is not a valid canonical entity id");
            }
            doc.meta.id = value;
        } else if (std.mem.eql(u8, key, "parent")) {
            if (saw_parent) {
                return fail(.EFRONTMATTER, line_no, col, "duplicate frontmatter key \"parent\"");
            }
            saw_parent = true;
            if (value.len > max_entity_id_bytes) {
                return fail(.EFRONTMATTER, line_no, col, "parent exceeds maximum length");
            }
            if (!identity.validateEntityId(value)) {
                return fail(.EFRONTMATTER, line_no, col, "parent is not a valid canonical entity id");
            }
            doc.meta.parent = value;
        } else if (std.mem.eql(u8, key, "status")) {
            if (saw_status) {
                return fail(.EFRONTMATTER, line_no, col, "duplicate frontmatter key \"status\"");
            }
            saw_status = true;
            if (Status.parse(value)) |st| {
                doc.meta.status = st;
            } else {
                return fail(.EFRONTMATTER, line_no, col, "status must be draft, published, or archived");
            }
        } else {
            // Closed key set — including legacy parentEntry / parent_entry.
            return fail(.EFRONTMATTER, line_no, col, "unsupported frontmatter key");
        }

        line_no += 1;
        if (!pl[2]) break;
        fline_start = pl[1];
    }

    return .{ .doc = doc };
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "parse: valid no-frontmatter document" {
    const src = "# Just a page\n\nHello.\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expect(!r.doc.has_frontmatter);
    try std.testing.expectEqual(@as(usize, 0), r.doc.body_offset);
    try std.testing.expectEqualStrings(src, r.doc.body);
    try std.testing.expect(r.doc.meta.title == null);
    try std.testing.expect(r.doc.meta.id == null);
    try std.testing.expect(r.doc.meta.parent == null);
    try std.testing.expect(r.doc.meta.status == null);
    try std.testing.expectEqual(@as(usize, 0), r.doc.meta.tag_count);
}

test "parse: empty file is valid no-frontmatter" {
    const r = parse("");
    try std.testing.expect(r.isOk());
    try std.testing.expect(!r.doc.has_frontmatter);
    try std.testing.expectEqualStrings("", r.doc.body);
    try std.testing.expect(r.doc.meta.title == null);
}

test "parse: valid frontmatter document" {
    const src =
        \\---
        \\id: guides/intro
        \\title: Introduction
        \\parent: home
        \\status: published
        \\tags: [guide, intro]
        \\---
        \\
        \\# Body starts here
        \\
    ;
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expect(r.doc.has_frontmatter);
    try std.testing.expectEqualStrings("guides/intro", r.doc.meta.id.?);
    try std.testing.expectEqualStrings("Introduction", r.doc.meta.title.?);
    try std.testing.expectEqualStrings("home", r.doc.meta.parent.?);
    try std.testing.expect(r.doc.meta.status.? == .published);
    try std.testing.expectEqual(@as(usize, 2), r.doc.meta.tag_count);
    try std.testing.expectEqualStrings("guide", r.doc.meta.tagsSlice()[0]);
    try std.testing.expectEqualStrings("intro", r.doc.meta.tagsSlice()[1]);
    try std.testing.expect(std.mem.startsWith(u8, r.doc.body, "\n# Body starts here"));
    // Views point into source.
    try std.testing.expect(@intFromPtr(r.doc.meta.title.?.ptr) >= @intFromPtr(src.ptr));
    try std.testing.expect(@intFromPtr(r.doc.body.ptr) >= @intFromPtr(src.ptr));
}

test "parse: CRLF input" {
    const src = "---\r\ntitle: CRLF Title\r\nstatus: draft\r\n---\r\n# Body\r\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("CRLF Title", r.doc.meta.title.?);
    try std.testing.expect(r.doc.meta.status.? == .draft);
    try std.testing.expectEqualStrings("# Body\r\n", r.doc.body);
}

test "parse: BOM rejected as EINVALIDUTF8" {
    const src = "\xEF\xBB\xBF---\ntitle: X\n---\n";
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EINVALIDUTF8);
    try std.testing.expectEqualStrings("UTF-8 BOM is not allowed", r.diagnostic.?.message);
}

test "parse: unclosed fence is EFRONTMATTER" {
    const src =
        \\---
        \\title: Unclosed
        \\status: draft
        \\
        \\# Body without closing fence
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "unclosed") != null);
}

test "parse: duplicate key is EFRONTMATTER" {
    const src =
        \\---
        \\title: First Title
        \\title: Second Title
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "duplicate") != null);
}

test "parse: unknown key is EFRONTMATTER" {
    const src =
        \\---
        \\title: X
        \\category: docs
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "unsupported") != null);
}

test "parse: legacy parentEntry is unknown key" {
    const src =
        \\---
        \\parentEntry: guides/intro
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
}

test "parse: nested mapping is EFRONTMATTER" {
    const src =
        \\---
        \\title:
        \\  en: Hello
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
}

test "parse: invalid tags syntax is EFRONTMATTER" {
    const src =
        \\---
        \\tags: not-a-list
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "tags") != null);
}

test "parse: overlong title is EFRONTMATTER" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\ntitle: ");
    try src.appendNTimes(gpa, 'X', max_title_bytes + 1);
    try src.appendSlice(gpa, "\n---\n");
    const r = parse(src.items);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "title") != null);
}

test "parse: overlong frontmatter block is EFRONTMATTER" {
    // Build: ---\n + (max+1) bytes of padding field content + \n---\n
    // Use a heap buffer; max_frontmatter_bytes is 64 KiB.
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\n");
    // One long line of 'x' as a bogus value would fail as unknown key first;
    // pad with a title value that itself is under title limit but bloated
    // via many blank-separated... actually simplest: many short valid lines
    // would hit field count. For block size, use one oversize plain line
    // without a colon so we hit size check before field parse.
    // Size check is on the whole block before field iteration.
    try src.appendNTimes(gpa, 'x', max_frontmatter_bytes + 1);
    try src.appendSlice(gpa, "\n---\n");
    const r = parse(src.items);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "frontmatter exceeds") != null);
}

test "parse: overlong source is EFRONTMATTER" {
    const gpa = std.testing.allocator;
    const n = max_source_bytes + 1;
    const buf = try gpa.alloc(u8, n);
    defer gpa.free(buf);
    @memset(buf, 'a');
    const r = parse(buf);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "source exceeds") != null);
}

test "parse: invalid UTF-8 is EINVALIDUTF8" {
    const src = "---\ntitle: Bad\n---\n\nbad: \xff more\n";
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EINVALIDUTF8);
}

test "parse: body-start boundary after closing fence" {
    const src = "---\ntitle: T\n---\nBODY";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("BODY", r.doc.body);
    try std.testing.expectEqual(@as(usize, src.len - 4), r.doc.body_offset);
}

test "parse: empty frontmatter yields empty body offset after fences" {
    const src = "---\n---\n# hi\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expect(r.doc.has_frontmatter);
    try std.testing.expectEqualStrings("# hi\n", r.doc.body);
    try std.testing.expect(r.doc.meta.title == null);
}

test "parse: leading space means no frontmatter" {
    const src = " ---\ntitle: X\n---\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expect(!r.doc.has_frontmatter);
    try std.testing.expectEqual(@as(usize, 0), r.doc.body_offset);
    try std.testing.expectEqualStrings(src, r.doc.body);
}

test "parse: invalid path id is EINVALIDPATH" {
    const src =
        \\---
        \\id: ../escape
        \\title: Bad Path Id
        \\---
        \\
    ;
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EINVALIDPATH);
}

test "parse: double-quoted title strips quotes; no escapes" {
    const src = "---\ntitle: \"Hello World\"\n---\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("Hello World", r.doc.meta.title.?);
}

test "parse: single-quoted value rejected" {
    const src = "---\ntitle: 'nope'\n---\n";
    const r = parse(src);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
}

test "parse: title may contain colons" {
    const src = "---\ntitle: Foo: Bar\n---\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("Foo: Bar", r.doc.meta.title.?);
}

test "parse: empty tags list" {
    const src = "---\ntags: []\n---\n";
    const r = parse(src);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqual(@as(usize, 0), r.doc.meta.tag_count);
}

test "parse: tag too long is EFRONTMATTER" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\ntags: [");
    try src.appendNTimes(gpa, 't', max_tag_bytes + 1);
    try src.appendSlice(gpa, "]\n---\n");
    const r = parse(src.items);
    try std.testing.expect(!r.isOk());
    try std.testing.expect(r.category().? == .EFRONTMATTER);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostic.?.message, "tag") != null);
}

test "parse: accepts title and id at exact length limits" {
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "---\ntitle: ");
    try src.appendNTimes(gpa, 'T', max_title_bytes);
    try src.appendSlice(gpa, "\nid: ");
    try src.appendNTimes(gpa, 'i', max_entity_id_bytes);
    try src.appendSlice(gpa, "\n---\n");
    const r = parse(src.items);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqual(@as(usize, max_title_bytes), r.doc.meta.title.?.len);
    try std.testing.expectEqual(@as(usize, max_entity_id_bytes), r.doc.meta.id.?.len);
}

// ---------------------------------------------------------------------------
// Fixture-driven tests (fixtures/ corpus)
// ---------------------------------------------------------------------------

fn readFixture(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const io = std.testing.io;
    var cwd = std.Io.Dir.cwd();
    var file = cwd.openFile(io, rel, .{}) catch |err| {
        std.log.err("open {s}: {s} (run tests with cwd at package root)", .{ rel, @errorName(err) });
        return err;
    };
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn expectFixtureCategory(rel: []const u8, expected: Category) !void {
    const gpa = std.testing.allocator;
    const path = try std.fmt.allocPrint(gpa, "fixtures/{s}", .{rel});
    defer gpa.free(path);
    const raw = try readFixture(gpa, path);
    defer gpa.free(raw);
    const r = parse(raw);
    try std.testing.expect(!r.isOk());
    try std.testing.expectEqual(expected, r.category().?);
}

test "fixture: valid empty-no-fm" {
    const gpa = std.testing.allocator;
    const raw = try readFixture(gpa, "fixtures/content/valid/empty-no-fm.md");
    defer gpa.free(raw);
    const r = parse(raw);
    try std.testing.expect(r.isOk());
    try std.testing.expect(!r.doc.has_frontmatter);
    try std.testing.expectEqual(@as(usize, 0), r.doc.body_offset);
    try std.testing.expect(r.doc.meta.title == null);
    try std.testing.expectEqualStrings(raw, r.doc.body);
}

test "fixture: valid trunk-root" {
    const gpa = std.testing.allocator;
    const raw = try readFixture(gpa, "fixtures/content/valid/trunk-root.md");
    defer gpa.free(raw);
    const r = parse(raw);
    try std.testing.expect(r.isOk());
    try std.testing.expect(r.doc.has_frontmatter);
    try std.testing.expectEqualStrings("home", r.doc.meta.id.?);
    try std.testing.expectEqualStrings("Home Trunk", r.doc.meta.title.?);
    try std.testing.expect(r.doc.meta.parent == null);
    try std.testing.expect(r.doc.meta.status.? == .published);
    try std.testing.expectEqual(@as(usize, 1), r.doc.meta.tag_count);
    try std.testing.expectEqualStrings("home", r.doc.meta.tagsSlice()[0]);
    try std.testing.expect(std.mem.indexOf(u8, r.doc.body, "# Home") != null);
}

test "fixture: valid satellite-child" {
    const gpa = std.testing.allocator;
    const raw = try readFixture(gpa, "fixtures/content/valid/satellite-child.md");
    defer gpa.free(raw);
    const r = parse(raw);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("home", r.doc.meta.parent.?);
    try std.testing.expectEqualStrings("Child Satellite", r.doc.meta.title.?);
    try std.testing.expect(r.doc.meta.status.? == .draft);
}

test "fixture: valid nested deep page" {
    const gpa = std.testing.allocator;
    const raw = try readFixture(gpa, "fixtures/content/valid/nested/deep/page.md");
    defer gpa.free(raw);
    const r = parse(raw);
    try std.testing.expect(r.isOk());
    try std.testing.expectEqualStrings("Nested Deep Page", r.doc.meta.title.?);
    try std.testing.expect(r.doc.meta.id == null); // path-derived later
    try std.testing.expect(r.doc.meta.parent == null);
}

test "fixture: invalid duplicate-key → EFRONTMATTER" {
    try expectFixtureCategory("content/invalid/duplicate-key.md", .EFRONTMATTER);
}

test "fixture: invalid unclosed-frontmatter → EFRONTMATTER" {
    try expectFixtureCategory("content/invalid/unclosed-frontmatter.md", .EFRONTMATTER);
}

test "fixture: invalid nested-mapping → EFRONTMATTER" {
    try expectFixtureCategory("content/invalid/nested-mapping.md", .EFRONTMATTER);
}

test "fixture: invalid invalid-utf8 → EINVALIDUTF8" {
    try expectFixtureCategory("content/invalid/invalid-utf8.md", .EINVALIDUTF8);
}

test "fixture: invalid invalid-path-id → EINVALIDPATH" {
    try expectFixtureCategory("content/invalid/invalid-path-id.md", .EINVALIDPATH);
}

test "fixture: graph-invalid files still parse (not parser errors)" {
    // These fail at graph time; the frontmatter grammar itself is valid.
    const paths = [_][]const u8{
        "fixtures/content/invalid/missing-parent.md",
        "fixtures/content/invalid/self-parent.md",
        "fixtures/content/invalid/cycle/a.md",
        "fixtures/content/invalid/cycle/b.md",
        "fixtures/content/invalid/duplicate-id/a.md",
        "fixtures/content/invalid/duplicate-id/b.md",
        "fixtures/content/invalid/satellite-of-satellite/trunk.md",
        "fixtures/content/invalid/satellite-of-satellite/mid.md",
        "fixtures/content/invalid/satellite-of-satellite/leaf.md",
    };
    const gpa = std.testing.allocator;
    for (paths) |p| {
        const raw = try readFixture(gpa, p);
        defer gpa.free(raw);
        const r = parse(raw);
        try std.testing.expect(r.isOk());
    }
}

test "Category.name matches contract strings" {
    try std.testing.expectEqualStrings("EFRONTMATTER", Category.EFRONTMATTER.name());
    try std.testing.expectEqualStrings("EINVALIDUTF8", Category.EINVALIDUTF8.name());
    try std.testing.expectEqualStrings("EINVALIDPATH", Category.EINVALIDPATH.name());
}
