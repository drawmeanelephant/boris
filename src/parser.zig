//! Pre-rendering metadata parser + constrained component tokenizer.
//!
//! 1. Parse **bounded frontmatter** (not YAML): optional `---` fences, one-line
//!    `key: value` fields only. Closed key set: `title`, `parent` /
//!    `parentEntry` / `parent_entry`, `id`, `status`, and `tags` (tags is the
//!    only deliberately supported list form: `[a, b]`).
//! 2. Single-pass scan of the body for **registered** component tags
//!    (`<Aside …>…</Aside>` only in v0.1) and produce an ordered segment list:
//!    markdown | aside | markdown | …
//!
//! This is **not** a generic HTML parser, **not** MDX, and **not** markdown
//! `:::directive` tokenization. Only the registered `Aside` component is
//! recognized; everything else is prose or a hard diagnostic.
//!
//! ## Zero-copy segment model
//!
//! Every string field on a segment is a slice into the original immutable
//! `source` buffer (or empty). The segment array itself is arena-owned.
//! Tokenization does not materialize new strings for tags/attrs/bodies.
//!
//! ## Encoding gate
//!
//! Valid UTF-8 is required before any byte-oriented component scan
//! (`parsePageSource` rejects BOM + invalid UTF-8; `parseBodySegments`
//! re-checks the body slice).
//!
//! ## Aside correctness rules (v0.1)
//!
//! - **Lexical name boundary:** `<Aside` is only an open tag when the next
//!   byte is whitespace, `/`, or `>`. `<AsideFoo` is one longer name, never
//!   an Aside open.
//! - **Attributes:** only `kind`, `id`, and legacy `type` (kind alias).
//!   Unknown names and **duplicate** names are hard errors.
//! - **Kind allowlist:** `note`, `tip`, `info`, `warning`, `danger` (when the
//!   attribute is present). Omitted kind is allowed (render/RAG default note).
//! - **Id grammar:** optional; when present must match
//!   `[A-Za-z0-9][A-Za-z0-9_-]*` (max 64 bytes) so values cannot break HTML
//!   attributes or RAG `:::kind{id="…"}` sinks without escaping.
//! - **Close tag:** only `</Aside>` at the **start of a logical line**,
//!   optionally preceded by ASCII spaces/tabs. Mid-line `</Aside>` (including
//!   examples and most fenced-code illustrations written inline) does **not**
//!   terminate the block. A line-start `</Aside>` inside a fence **does**
//!   close — fences are not a second grammar.
//! - **Unterminated:** open without a line-start close is a precise hard error;
//!   the remainder is not swallowed as aside body.
//! - **Nested Aside:** unsupported. A second `<Aside` open before the
//!   matching line-start close is a hard error (not balanced / not MDX).
//!
//! ## Unregistered components
//!
//! Any substring matching a PascalCase open tag `<[A-Z][A-Za-z0-9_-]*` that is
//! **not** in the allowlist (`Aside`) is a hard diagnostic (file/line/col +
//! name). Authors get build errors, not silent HTML leakage into `dist/`.
//!
//! ## Naming
//!
//! Canonical component name is **Aside**. Legacy mascot branding ("Broside")
//! is not accepted as a tag and is not a registered component.
//!
//! Unknown tags and unterminated components are hard errors. `body_md`
//! (component-stripped) is stitched from the markdown segments only — not a
//! second independent scan of raw source.

const std = @import("std");
const page_mod = @import("page.zig");
const aside_mod = @import("aside.zig");
const Page = page_mod.Page;
const Frontmatter = page_mod.Frontmatter;
const Aside = aside_mod.Aside;

pub const ParseError = error{
    UnclosedFrontmatter,
    UnterminatedComponent,
    UnregisteredComponent,
    MalformedAttributes,
    InvalidUtf8,
    /// UTF-8 BOM (EF BB BF) at file start — rejected, never stripped.
    Utf8Bom,
    /// Promoted string exceeded PageDb length bound (title / entity id / parent).
    FrontmatterValueTooLong,
} || std.mem.Allocator.Error;

/// Max UTF-8 bytes inside the frontmatter fences (excluding the fences themselves).
pub const max_frontmatter_bytes: usize = 64 * 1024;

/// Max non-empty field lines inside one frontmatter block.
pub const max_frontmatter_keys: usize = 32;

/// Structured component/parse diagnostic (multi-issue collection).
/// Strings are slices into source or static literals (zero-copy where possible).
/// Callers that put results on PageDb must **dupe** promoted strings before
/// resetting the document/whiteboard arena — never store these slices on Page.
pub const ParseDiag = struct {
    pub const Kind = enum {
        unregistered_component,
        unterminated_component,
        malformed_attributes,
        /// Aside `kind` / legacy `type` not in the supported allowlist.
        invalid_kind,
        /// Aside `id` fails the safe-identifier grammar.
        invalid_id,
        /// Same attribute name twice on one open tag.
        duplicate_attribute,
        /// Attribute name not in the Aside allowlist.
        unknown_attribute,
        /// Nested `<Aside` open before the matching line-start close.
        nested_component,
        unclosed_frontmatter,
        /// Title / entity-id-like frontmatter value over PageDb length bound.
        value_too_long,
        /// Frontmatter block over `max_frontmatter_bytes` or too many keys.
        frontmatter_limit,
        /// Same key twice, or two parent aliases together.
        duplicate_key,
        /// Line is not `key: value` under the bounded grammar.
        malformed_line,
        /// Nested / sequence / block-scalar / anchor / alias / flow form.
        unsupported_syntax,
        /// Key not in the closed recognized set for this parser.
        unknown_key,
        /// Empty value where a non-empty scalar is required.
        empty_value,
        /// Single quotes, unclosed/broken double quotes, or escape forms.
        bad_quote,
    };

    kind: Kind,
    /// Component tag name when applicable (slice into source), else "".
    component_name: []const u8 = "",
    /// 1-based line in the full source file.
    line: u32 = 1,
    /// 1-based byte column within the line.
    column: u32 = 1,
    /// Human-readable message (static or arena-owned).
    message: []const u8 = "",
};

/// One piece of a page body, in document order.
pub const Segment = union(enum) {
    /// Markdown prose (slice into original source). Never contains tokenized Aside tags.
    markdown: []const u8,
    /// Built-in admonition component (fields are source slices).
    aside: Aside,
};

/// Result of pre-rendering parse.
pub const ParsedPage = struct {
    frontmatter: Frontmatter,
    /// Ordered body parts for zero-copy compile splicing.
    segments: []const Segment,
    /// Convenience: all Aside nodes (same memory as in segments).
    asides: []const Aside,
    /// Markdown-only body with components stripped (joined from markdown segments).
    body_md: []const u8,
    /// Collected parse issues (empty ⇒ success). Hard errors for components.
    diagnostics: []const ParseDiag = &.{},

    pub fn hasErrors(self: ParsedPage) bool {
        return self.diagnostics.len > 0;
    }
};

pub const BodyParseResult = struct {
    segments: []const Segment,
    asides: []const Aside,
    body_md: []const u8,
    diagnostics: []const ParseDiag = &.{},

    pub fn hasErrors(self: BodyParseResult) bool {
        return self.diagnostics.len > 0;
    }
};

/// Sole registered component name in v0.1.
pub const registered_aside = "Aside";

/// Max bytes for a validated Aside `id` attribute.
pub const max_aside_id_bytes: usize = 64;

/// Supported Aside `kind` / legacy `type` values (closed allowlist).
pub const allowed_aside_kinds = [_][]const u8{ "note", "tip", "info", "warning", "danger" };

const open_aside = "<Aside";
const close_aside = "</Aside>";

// ---------------------------------------------------------------------------
// Line / column helpers
// ---------------------------------------------------------------------------

/// 1-based line and column for a byte offset into `source`.
pub fn lineColAt(source: []const u8, offset: usize) struct { line: u32, column: u32 } {
    var line: u32 = 1;
    var column: u32 = 1;
    const lim = @min(offset, source.len);
    var i: usize = 0;
    while (i < lim) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }
    return .{ .line = line, .column = column };
}

fn absOffset(body_start: usize, body_index: usize) usize {
    return body_start + body_index;
}

// ---------------------------------------------------------------------------
// Frontmatter (bounded grammar — not YAML)
// ---------------------------------------------------------------------------
//
// Normative summary (HTML / RAG parser dialect; see docs/contracts/frontmatter.md):
//
// - Source must be valid UTF-8; UTF-8 BOM is **rejected** (not stripped).
// - LF and CRLF line endings are accepted.
// - Frontmatter is optional. Opening fence is recognized only when the first
//   line of the file is exactly `---` at column zero (byte zero of the file).
// - Closing fence is a complete line that is exactly `---` at column zero.
// - Only one-line `key: value` scalars. No nested maps, sequences, block
//   scalars (`|` / `>`), anchors, aliases, or multiline forms.
// - Double-quoted values: surrounding `"` stripped; no escapes; no raw `"` inside.
// - Single-quoted values are rejected.
// - Recognized keys: `title`, `parent` | `parentEntry` | `parent_entry`, `id`,
//   `status`, `tags` (bracket list only).
// - Duplicate recognized keys (including any two parent aliases) are hard errors.
// - Bounds: max_frontmatter_bytes, max_frontmatter_keys, max_title_bytes,
//   max_entity_id_bytes. Oversize values are not stored (no PageDb promotion).
//
// Returned Frontmatter string fields are slices into `source` (document arena).
// PageDb / long-lived storage must dupe via promoteFrontmatter (compile.zig).

const ScalarError = error{
    EmptyValue,
    SingleQuote,
    BadQuote,
    BlockScalar,
    FlowCollection,
    AnchorAlias,
};

fn trimAscii(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t");
}

fn isParentKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "parent") or
        std.mem.eql(u8, key, "parentEntry") or
        std.mem.eql(u8, key, "parent_entry");
}

/// Parse a one-line scalar value under the bounded grammar.
/// `raw` is the text after the first `:` on the field line (may include spaces).
fn parseScalarValue(raw: []const u8) ScalarError![]const u8 {
    const v = trimAscii(raw);
    if (v.len == 0) return error.EmptyValue;

    // Explicitly reject YAML block scalars and flow collections — do not half-parse.
    if (v[0] == '|' or v[0] == '>') return error.BlockScalar;
    if (v[0] == '[' or v[0] == '{') return error.FlowCollection;
    if (v[0] == '&' or v[0] == '*') return error.AnchorAlias;

    if (v[0] == '\'') return error.SingleQuote;

    if (v[0] == '"') {
        if (v.len < 2 or v[v.len - 1] != '"') return error.BadQuote;
        const inner = v[1 .. v.len - 1];
        // No escape sequences in v0.1; embedded raw `"` is illegal.
        if (std.mem.indexOfScalar(u8, inner, '"') != null) return error.BadQuote;
        if (inner.len == 0) return error.EmptyValue;
        return inner;
    }

    return v;
}

/// Deliberately supported tags form: `tags: [a, b, "c"]` only (not general YAML).
/// Returns true when the raw value is a well-formed bracket list of plain/dquoted items.
fn validateTagsList(raw: []const u8) bool {
    const v = trimAscii(raw);
    if (v.len < 2 or v[0] != '[' or v[v.len - 1] != ']') return false;
    const inner = trimAscii(v[1 .. v.len - 1]);
    if (inner.len == 0) return true;

    var i: usize = 0;
    while (i < inner.len) {
        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;

        if (inner[i] == '"') {
            i += 1;
            while (i < inner.len and inner[i] != '"') : (i += 1) {}
            if (i >= inner.len) return false;
            i += 1;
        } else if (inner[i] == '\'') {
            return false; // single quotes not supported in tag items either
        } else {
            while (i < inner.len and inner[i] != ',' and inner[i] != ' ' and inner[i] != '\t') : (i += 1) {}
        }

        while (i < inner.len and (inner[i] == ' ' or inner[i] == '\t')) : (i += 1) {}
        if (i >= inner.len) break;
        if (inner[i] != ',') return false;
        i += 1;
    }
    return true;
}

fn isStatusValue(v: []const u8) bool {
    return std.mem.eql(u8, v, "draft") or
        std.mem.eql(u8, v, "published") or
        std.mem.eql(u8, v, "archived");
}

fn keyColumnInLine(line: []const u8, key: []const u8) u32 {
    if (std.mem.indexOf(u8, line, key)) |idx| {
        return @intCast(idx + 1);
    }
    return 1;
}

fn appendFmDiag(
    arena: std.mem.Allocator,
    diags: *std.ArrayList(ParseDiag),
    kind: ParseDiag.Kind,
    line: u32,
    column: u32,
    message: []const u8,
) !void {
    try diags.append(arena, .{
        .kind = kind,
        .line = line,
        .column = column,
        .message = message,
    });
}

/// Read one physical line ending at `\n` (CRLF tolerated). Returns
/// `(content_without_cr, next_offset, saw_newline)`.
fn readPhysicalLine(source: []const u8, start: usize) struct { []const u8, usize, bool } {
    var end = start;
    while (end < source.len and source[end] != '\n') : (end += 1) {}
    var line = source[start..end];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    if (end < source.len and source[end] == '\n') {
        return .{ line, end + 1, true };
    }
    return .{ line, end, false };
}

/// Parse frontmatter delimited by leading `---` at byte/column zero.
/// Returns (frontmatter, body_start_offset, frontmatter diagnostics).
///
/// Content issues are aggregated as diagnostics (except unclosed fence, which
/// still returns `error.UnclosedFrontmatter` so callers abort the page).
/// Oversize / illegal values are **not** stored on the returned Frontmatter.
pub fn parseFrontmatter(source: []const u8, arena: std.mem.Allocator) ParseError!struct { Frontmatter, usize, []const ParseDiag } {
    var fm: Frontmatter = .{};
    var fm_diags: std.ArrayList(ParseDiag) = .empty;

    // Optional: no fence at column zero → entire file is body.
    if (source.len == 0) {
        return .{ fm, 0, try fm_diags.toOwnedSlice(arena) };
    }

    const first = readPhysicalLine(source, 0);
    if (!std.mem.eql(u8, first[0], "---")) {
        // Not a complete opening fence at col 0 — no frontmatter.
        return .{ fm, 0, try fm_diags.toOwnedSlice(arena) };
    }
    // Opening fence must be a complete line (terminated by newline), not EOF alone
    // unless the file is only `---` (still unclosed — handled below).
    if (!first[2] and source.len > 0) {
        // File is exactly `---` or `---\r` with no newline after fields possible.
        // Treat as opened but unclosed.
        return error.UnclosedFrontmatter;
    }

    const fm_start = first[1];
    var close: ?usize = null;
    var line_start = fm_start;
    while (line_start <= source.len) {
        if (line_start >= source.len) break;
        const pl = readPhysicalLine(source, line_start);
        const line = pl[0];
        if (std.mem.eql(u8, line, "---")) {
            // Closing fence must start at column zero (no leading whitespace).
            // readPhysicalLine already gives the full line; equality enforces exact `---`.
            close = line_start;
            break;
        }
        if (!pl[2]) break; // last line without newline — not a closing fence
        line_start = pl[1];
    }

    if (close == null) return error.UnclosedFrontmatter;

    const fm_block = source[fm_start..close.?];
    if (fm_block.len > max_frontmatter_bytes) {
        try appendFmDiag(
            arena,
            &fm_diags,
            .frontmatter_limit,
            1,
            1,
            try std.fmt.allocPrint(arena, "frontmatter exceeds maximum of {d} bytes (got {d})", .{ max_frontmatter_bytes, fm_block.len }),
        );
        // Still parse for additional diagnostics, but do not store any values.
    }

    var extras: std.ArrayList(Frontmatter.Kv) = .empty;
    var saw_title = false;
    var saw_id = false;
    var saw_parent = false;
    var saw_status = false;
    var saw_tags = false;
    var first_parent_key: []const u8 = "";
    var key_count: usize = 0;
    const block_oversize = fm_block.len > max_frontmatter_bytes;

    // Opening --- is line 1; first field is line 2.
    var line_no: u32 = 2;
    var fline_start: usize = 0;
    while (fline_start <= fm_block.len) {
        if (fline_start >= fm_block.len) break;
        const pl = readPhysicalLine(fm_block, fline_start);
        const raw_line = pl[0];

        // Blank lines (optional whitespace only) are skipped.
        if (trimAscii(raw_line).len == 0) {
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        // Nested YAML-ish indentation at column zero is not supported.
        if (raw_line[0] == ' ' or raw_line[0] == '\t') {
            try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, 1, "indented frontmatter lines are not supported (no nested mappings)");
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        // Sequence item form.
        if (raw_line.len >= 2 and raw_line[0] == '-' and (raw_line[1] == ' ' or raw_line[1] == '\t')) {
            try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, 1, "YAML sequences are not supported in frontmatter");
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        // Anchors / aliases as whole-line forms.
        if (raw_line[0] == '&' or raw_line[0] == '*') {
            try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, 1, "YAML anchors and aliases are not supported");
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        const colon = std.mem.indexOfScalar(u8, raw_line, ':') orelse {
            try appendFmDiag(arena, &fm_diags, .malformed_line, line_no, 1, "malformed frontmatter line (expected key: value)");
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        };

        const key = trimAscii(raw_line[0..colon]);
        const raw_val = raw_line[colon + 1 ..];
        const col = keyColumnInLine(raw_line, key);

        if (key.len == 0) {
            try appendFmDiag(arena, &fm_diags, .malformed_line, line_no, 1, "empty frontmatter key");
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        key_count += 1;
        if (key_count > max_frontmatter_keys) {
            try appendFmDiag(
                arena,
                &fm_diags,
                .frontmatter_limit,
                line_no,
                col,
                try std.fmt.allocPrint(arena, "frontmatter exceeds maximum of {d} keys", .{max_frontmatter_keys}),
            );
            // Stop accepting further fields; keep scanning for diagnostics cost bound.
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        // `tags` is the only deliberately supported non-scalar form.
        if (std.mem.eql(u8, key, "tags")) {
            if (saw_tags) {
                try appendFmDiag(arena, &fm_diags, .duplicate_key, line_no, col, "duplicate frontmatter key \"tags\"");
            } else {
                saw_tags = true;
                if (!validateTagsList(raw_val)) {
                    try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, col, "tags must be a simple list like [a, b] with plain or double-quoted items");
                }
                // Validated only; not promoted onto Page (HTML path does not use tags).
            }
            line_no += 1;
            if (!pl[2]) break;
            fline_start = pl[1];
            continue;
        }

        const value_or_err = parseScalarValue(raw_val);
        const value: ?[]const u8 = value_or_err catch |err| blk: {
            switch (err) {
                error.EmptyValue => try appendFmDiag(arena, &fm_diags, .empty_value, line_no, col, "frontmatter value must be a non-empty plain or double-quoted string"),
                error.SingleQuote => try appendFmDiag(arena, &fm_diags, .bad_quote, line_no, col, "single-quoted values are not supported; use plain text or double quotes"),
                error.BadQuote => try appendFmDiag(arena, &fm_diags, .bad_quote, line_no, col, "malformed double-quoted string (no escapes; no embedded raw quotes)"),
                error.BlockScalar => try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, col, "YAML block scalars (| and >) are not supported"),
                error.FlowCollection => try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, col, "YAML flow sequences/mappings ([ ] { }) are not supported"),
                error.AnchorAlias => try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, col, "YAML anchors and aliases are not supported"),
            }
            break :blk null;
        };

        if (value) |v| {
            if (std.mem.eql(u8, key, "title")) {
                if (saw_title) {
                    try appendFmDiag(arena, &fm_diags, .duplicate_key, line_no, col, "duplicate frontmatter key \"title\"");
                } else {
                    saw_title = true;
                    if (!block_oversize and key_count <= max_frontmatter_keys) {
                        if (v.len > page_mod.max_title_bytes) {
                            try appendFmDiag(
                                arena,
                                &fm_diags,
                                .value_too_long,
                                line_no,
                                col,
                                try std.fmt.allocPrint(arena, "title exceeds maximum length of {d} bytes (got {d})", .{ page_mod.max_title_bytes, v.len }),
                            );
                        } else {
                            fm.title = v;
                        }
                    }
                }
            } else if (isParentKey(key)) {
                if (saw_parent) {
                    const msg = try std.fmt.allocPrint(
                        arena,
                        "duplicate parent key: \"{s}\" conflicts with earlier \"{s}\"",
                        .{ key, first_parent_key },
                    );
                    try appendFmDiag(arena, &fm_diags, .duplicate_key, line_no, col, msg);
                } else {
                    saw_parent = true;
                    first_parent_key = key;
                    if (!block_oversize and key_count <= max_frontmatter_keys) {
                        if (v.len > page_mod.max_entity_id_bytes) {
                            try appendFmDiag(
                                arena,
                                &fm_diags,
                                .value_too_long,
                                line_no,
                                col,
                                try std.fmt.allocPrint(arena, "parent entity id exceeds maximum length of {d} bytes (got {d})", .{ page_mod.max_entity_id_bytes, v.len }),
                            );
                        } else {
                            fm.parent_entry = v;
                        }
                    }
                }
            } else if (std.mem.eql(u8, key, "id")) {
                if (saw_id) {
                    try appendFmDiag(arena, &fm_diags, .duplicate_key, line_no, col, "duplicate frontmatter key \"id\"");
                } else {
                    saw_id = true;
                    if (!block_oversize and key_count <= max_frontmatter_keys) {
                        if (v.len > page_mod.max_entity_id_bytes) {
                            try appendFmDiag(
                                arena,
                                &fm_diags,
                                .value_too_long,
                                line_no,
                                col,
                                try std.fmt.allocPrint(arena, "id exceeds maximum length of {d} bytes (got {d})", .{ page_mod.max_entity_id_bytes, v.len }),
                            );
                        } else {
                            try extras.append(arena, .{ .key = key, .value = v });
                        }
                    }
                }
            } else if (std.mem.eql(u8, key, "status")) {
                if (saw_status) {
                    try appendFmDiag(arena, &fm_diags, .duplicate_key, line_no, col, "duplicate frontmatter key \"status\"");
                } else {
                    saw_status = true;
                    if (!isStatusValue(v)) {
                        try appendFmDiag(arena, &fm_diags, .unsupported_syntax, line_no, col, "status must be draft, published, or archived");
                    }
                    // Validated only; HTML path does not promote status onto Page.
                }
            } else {
                try appendFmDiag(
                    arena,
                    &fm_diags,
                    .unknown_key,
                    line_no,
                    col,
                    try std.fmt.allocPrint(arena, "unsupported frontmatter key \"{s}\"", .{key}),
                );
            }
        }

        line_no += 1;
        if (!pl[2]) break;
        fline_start = pl[1];
    }

    fm.extras = try extras.toOwnedSlice(arena);

    var body_off = close.?;
    body_off += 3;
    if (body_off < source.len and source[body_off] == '\r') body_off += 1;
    if (body_off < source.len and source[body_off] == '\n') body_off += 1;

    return .{ fm, body_off, try fm_diags.toOwnedSlice(arena) };
}

// ---------------------------------------------------------------------------
// Lexical boundary checks (not naive substring matches)
// ---------------------------------------------------------------------------

fn isIdentContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// After a component name, next byte must be a real tag boundary.
fn isTagNameBoundary(c: u8) bool {
    return c == '>' or std.ascii.isWhitespace(c) or c == '/';
}

/// True when `at` starts a real `<Aside` open tag (not `<AsideFoo`).
fn isAsideOpenAt(body: []const u8, at: usize) bool {
    if (at + open_aside.len > body.len) return false;
    if (!std.mem.eql(u8, body[at .. at + open_aside.len], open_aside)) return false;
    const after = at + open_aside.len;
    if (after >= body.len) return false;
    return isTagNameBoundary(body[after]);
}

/// True when `at` starts a real `</Aside>` close tag (not `</AsideFoo>`).
fn isAsideCloseAt(body: []const u8, at: usize) bool {
    if (at + close_aside.len > body.len) return false;
    if (!std.mem.eql(u8, body[at .. at + close_aside.len], close_aside)) return false;
    // close_aside includes '>'; if a longer name existed it would not match
    // `</Aside>` exactly. Boundary is already terminal via `>`.
    return true;
}

/// If `at` starts a PascalCase open component tag `<Name…`, return `Name`
/// as a slice into `body`. Closing tags and lowercase HTML are ignored.
fn componentOpenNameAt(body: []const u8, at: usize) ?[]const u8 {
    if (at >= body.len or body[at] != '<') return null;
    if (at + 1 >= body.len) return null;
    // Skip closing tags — handled by Aside close matcher.
    if (body[at + 1] == '/') return null;
    if (!std.ascii.isUpper(body[at + 1])) return null;

    const name_start = at + 1;
    var i = name_start;
    while (i < body.len and isIdentContinue(body[i])) : (i += 1) {}
    if (i == name_start) return null;
    // First char already checked uppercase; require real boundary after name
    // so `<AsideFoo` is one long name (not open Aside + "Foo").
    if (i >= body.len or !isTagNameBoundary(body[i])) return null;
    return body[name_start..i];
}

fn isRegisteredComponent(name: []const u8) bool {
    return std.mem.eql(u8, name, registered_aside);
}

// ---------------------------------------------------------------------------
// Attribute parsing (hand-rolled, constrained — not HTML)
// ---------------------------------------------------------------------------

fn isAttrNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c);
}

fn isAttrNameContinue(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// True when `kind` is in the closed Aside kind allowlist.
pub fn isAllowedAsideKind(kind: []const u8) bool {
    for (allowed_aside_kinds) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

/// Safe Aside `id` grammar: `[A-Za-z0-9][A-Za-z0-9_-]*`, length 1…max_aside_id_bytes.
/// Rejects quotes, spaces, `}`, `<`, and other characters that can break HTML
/// attributes or RAG `:::kind{id="…"}` directive syntax.
pub fn isSafeAsideId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_aside_id_bytes) return false;
    if (!std.ascii.isAlphanumeric(id[0])) return false;
    for (id[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn isAllowedAsideAttrName(name: []const u8) bool {
    return std.mem.eql(u8, name, "kind") or
        std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "type");
}

/// Attribute value for `name="..."` or `name='...'` inside an opening tag.
/// Returns a slice into `tag_header` (zero-copy). Empty if absent/malformed.
/// Prefer `parseAsideOpenAttrs` for validated component opens.
pub fn attrValue(tag_header: []const u8, name: []const u8) []const u8 {
    var search_from: usize = 0;
    while (search_from < tag_header.len) {
        const rel = std.mem.indexOf(u8, tag_header[search_from..], name) orelse return "";
        const at = search_from + rel;

        // Key boundary: start, whitespace, or '<' before the name.
        if (at > 0) {
            const prev = tag_header[at - 1];
            if (!std.ascii.isWhitespace(prev) and prev != '<' and prev != '/') {
                search_from = at + 1;
                continue;
            }
        }
        // Name must end at '=' / whitespace (not a prefix of a longer key).
        const after_name = at + name.len;
        if (after_name < tag_header.len) {
            const n = tag_header[after_name];
            if (n != '=' and !std.ascii.isWhitespace(n)) {
                search_from = at + 1;
                continue;
            }
        }

        var i = after_name;
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
        if (i >= tag_header.len or tag_header[i] != '=') {
            search_from = at + 1;
            continue;
        }
        i += 1;
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
        if (i >= tag_header.len) return "";

        const quote = tag_header[i];
        if (quote == '"' or quote == '\'') {
            i += 1;
            const vstart = i;
            while (i < tag_header.len and tag_header[i] != quote) : (i += 1) {}
            if (i >= tag_header.len) return ""; // unclosed quote → empty (caller may diag)
            return tag_header[vstart..i];
        }

        // Unquoted attribute value: read until whitespace or '>' or '/'.
        const vstart = i;
        while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '>' and tag_header[i] != '/') : (i += 1) {}
        return tag_header[vstart..i];
    }
    return "";
}

const AsideOpenAttrs = struct {
    kind: []const u8 = "",
    id: []const u8 = "",
    /// false when any attribute-related diagnostic was emitted.
    valid: bool = true,
};

/// Parse and validate attributes on an Aside open tag header (`<Aside …>`).
/// Zero-copy values; diagnostics for unknown / duplicate / invalid kind|id.
fn parseAsideOpenAttrs(
    tag_header: []const u8,
    diags: *std.ArrayList(ParseDiag),
    arena: std.mem.Allocator,
    full_source: []const u8,
    abs_tag_start: usize,
) !AsideOpenAttrs {
    var result: AsideOpenAttrs = .{};
    if (tag_header.len < open_aside.len or !std.mem.startsWith(u8, tag_header, open_aside)) {
        result.valid = false;
        try appendDiag(diags, arena, .malformed_attributes, registered_aside, full_source, abs_tag_start, "Aside opening tag is malformed");
        return result;
    }

    var i: usize = open_aside.len;
    var saw_kind = false;
    var saw_type = false;
    var saw_id = false;
    var kind_val: []const u8 = "";
    var type_val: []const u8 = "";
    var id_val: []const u8 = "";

    while (i < tag_header.len) {
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
        if (i >= tag_header.len) break;

        if (tag_header[i] == '/') {
            i += 1;
            while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
            if (i < tag_header.len and tag_header[i] == '>') {
                i += 1;
            } else {
                result.valid = false;
                try appendDiag(diags, arena, .malformed_attributes, registered_aside, full_source, abs_tag_start, "Aside self-closing tag is malformed");
            }
            break;
        }
        if (tag_header[i] == '>') {
            i += 1;
            break;
        }

        if (!isAttrNameStart(tag_header[i])) {
            result.valid = false;
            try appendDiag(diags, arena, .malformed_attributes, registered_aside, full_source, abs_tag_start, "Aside attribute name must start with a letter");
            break;
        }
        const name_start = i;
        i += 1;
        while (i < tag_header.len and isAttrNameContinue(tag_header[i])) : (i += 1) {}
        const attr_name = tag_header[name_start..i];

        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
        if (i >= tag_header.len or tag_header[i] != '=') {
            result.valid = false;
            try appendDiag(
                diags,
                arena,
                .malformed_attributes,
                registered_aside,
                full_source,
                abs_tag_start,
                try std.fmt.allocPrint(arena, "Aside attribute \"{s}\" is missing '='", .{attr_name}),
            );
            break;
        }
        i += 1;
        while (i < tag_header.len and std.ascii.isWhitespace(tag_header[i])) : (i += 1) {}
        if (i >= tag_header.len) {
            result.valid = false;
            try appendDiag(diags, arena, .malformed_attributes, registered_aside, full_source, abs_tag_start, "Aside attribute value is missing");
            break;
        }

        const value: []const u8 = blk: {
            const quote = tag_header[i];
            if (quote == '"' or quote == '\'') {
                i += 1;
                const vstart = i;
                while (i < tag_header.len and tag_header[i] != quote) : (i += 1) {}
                if (i >= tag_header.len) {
                    result.valid = false;
                    try appendDiag(diags, arena, .malformed_attributes, registered_aside, full_source, abs_tag_start, "Aside attribute value has an unclosed quote");
                    return result;
                }
                const v = tag_header[vstart..i];
                i += 1; // closing quote
                break :blk v;
            }
            const vstart = i;
            while (i < tag_header.len and !std.ascii.isWhitespace(tag_header[i]) and tag_header[i] != '>' and tag_header[i] != '/') : (i += 1) {}
            break :blk tag_header[vstart..i];
        };

        if (!isAllowedAsideAttrName(attr_name)) {
            result.valid = false;
            try appendDiag(
                diags,
                arena,
                .unknown_attribute,
                registered_aside,
                full_source,
                abs_tag_start,
                try std.fmt.allocPrint(arena, "unknown Aside attribute \"{s}\" (allowed: kind, id, type)", .{attr_name}),
            );
            continue;
        }

        if (std.mem.eql(u8, attr_name, "kind")) {
            if (saw_kind) {
                result.valid = false;
                try appendDiag(diags, arena, .duplicate_attribute, registered_aside, full_source, abs_tag_start, "duplicate Aside attribute \"kind\"");
            } else {
                saw_kind = true;
                kind_val = value;
            }
        } else if (std.mem.eql(u8, attr_name, "type")) {
            if (saw_type) {
                result.valid = false;
                try appendDiag(diags, arena, .duplicate_attribute, registered_aside, full_source, abs_tag_start, "duplicate Aside attribute \"type\"");
            } else {
                saw_type = true;
                type_val = value;
            }
        } else if (std.mem.eql(u8, attr_name, "id")) {
            if (saw_id) {
                result.valid = false;
                try appendDiag(diags, arena, .duplicate_attribute, registered_aside, full_source, abs_tag_start, "duplicate Aside attribute \"id\"");
            } else {
                saw_id = true;
                id_val = value;
            }
        }
    }

    // Resolve kind: prefer kind=, else legacy type=. Omitted both → empty (render default).
    // When either attribute is present, the value must be non-empty and allowlisted.
    const resolved_kind = if (saw_kind) kind_val else if (saw_type) type_val else "";
    if (saw_kind and (kind_val.len == 0 or !isAllowedAsideKind(kind_val))) {
        result.valid = false;
        try appendDiag(
            diags,
            arena,
            .invalid_kind,
            registered_aside,
            full_source,
            abs_tag_start,
            try std.fmt.allocPrint(arena, "invalid Aside kind \"{s}\" (allowed: note, tip, info, warning, danger)", .{kind_val}),
        );
    }
    if (saw_type and (type_val.len == 0 or !isAllowedAsideKind(type_val))) {
        result.valid = false;
        try appendDiag(
            diags,
            arena,
            .invalid_kind,
            registered_aside,
            full_source,
            abs_tag_start,
            try std.fmt.allocPrint(arena, "invalid Aside type \"{s}\" (allowed: note, tip, info, warning, danger)", .{type_val}),
        );
    }

    if (saw_id) {
        if (!isSafeAsideId(id_val)) {
            result.valid = false;
            try appendDiag(
                diags,
                arena,
                .invalid_id,
                registered_aside,
                full_source,
                abs_tag_start,
                "Aside id must match [A-Za-z0-9][A-Za-z0-9_-]* (max 64 bytes); quotes and special characters are not allowed",
            );
        }
    }

    if (result.valid) {
        result.kind = resolved_kind;
        result.id = if (saw_id) id_val else "";
    }
    return result;
}

fn trimInnerNewlines(inner: []const u8) []const u8 {
    var s = inner;
    if (s.len > 0 and s[0] == '\r') s = s[1..];
    if (s.len > 0 and s[0] == '\n') s = s[1..];
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (s.len > 0 and s[s.len - 1] == '\r') s = s[0 .. s.len - 1];
    return s;
}

fn findOpenTagEnd(body: []const u8, tag_start: usize) ?usize {
    var i = tag_start;
    var quote: ?u8 = null;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '>') return i;
    }
    return null;
}

fn isSelfClosing(tag_header: []const u8) bool {
    if (tag_header.len < 2) return false;
    if (tag_header[tag_header.len - 1] != '>') return false;
    var i = tag_header.len - 2;
    while (i > 0 and std.ascii.isWhitespace(tag_header[i])) : (i -= 1) {}
    return tag_header[i] == '/';
}

/// Byte offset of the start of the logical line containing `at` (after prior `\n`, or 0).
fn logicalLineStart(body: []const u8, at: usize) usize {
    var i = at;
    while (i > 0 and body[i - 1] != '\n') : (i -= 1) {}
    return i;
}

/// True when `at` is `</Aside>` at the start of a logical line (optional ASCII spaces/tabs only).
/// Mid-line `</Aside>` never closes a block — prevents prose/examples from terminating asides.
fn isAsideCloseAtLineStart(body: []const u8, at: usize) bool {
    if (!isAsideCloseAt(body, at)) return false;
    const ls = logicalLineStart(body, at);
    var i = ls;
    while (i < at) : (i += 1) {
        if (body[i] != ' ' and body[i] != '\t') return false;
    }
    return true;
}

const AsideCloseScan = struct {
    /// Offset of line-start `</Aside>`, or null if unterminated.
    close_at: ?usize = null,
    /// First nested `<Aside` open before close, if any.
    nested_open_at: ?usize = null,
};

/// Scan for the matching line-start close and any nested open (unsupported).
fn scanAsideClose(body: []const u8, from: usize) AsideCloseScan {
    var i = from;
    var nested: ?usize = null;
    while (i < body.len) {
        if (body[i] == '<') {
            if (isAsideCloseAtLineStart(body, i)) {
                return .{ .close_at = i, .nested_open_at = nested };
            }
            if (isAsideOpenAt(body, i)) {
                if (nested == null) nested = i;
            }
        }
        i += 1;
    }
    return .{ .close_at = null, .nested_open_at = nested };
}

fn appendDiag(
    diags: *std.ArrayList(ParseDiag),
    arena: std.mem.Allocator,
    kind: ParseDiag.Kind,
    component_name: []const u8,
    full_source: []const u8,
    abs_off: usize,
    message: []const u8,
) !void {
    const lc = lineColAt(full_source, abs_off);
    try diags.append(arena, .{
        .kind = kind,
        .component_name = component_name,
        .line = lc.line,
        .column = lc.column,
        .message = message,
    });
}

// ---------------------------------------------------------------------------
// Body tokenizer (single forward pass)
// ---------------------------------------------------------------------------

/// Parse body into ordered segments. All Aside fields are source slices.
///
/// `full_source` + `body_start` locate diagnostics in the original file
/// (pass `body` / `0` when the body is the whole buffer, e.g. unit tests).
///
/// Requires valid UTF-8 in `body` (re-checked here for direct call sites).
/// Diagnostics are collected rather than fail-fast so authors can fix several
/// typos in one build. Callers must refuse to emit HTML when `hasErrors()`.
pub fn parseBodySegments(
    body: []const u8,
    arena: std.mem.Allocator,
    full_source: []const u8,
    body_start: usize,
) ParseError!BodyParseResult {
    // Encoding gate before any byte-oriented tag scan.
    if (body.len > 0 and !std.unicode.utf8ValidateSlice(body)) {
        return error.InvalidUtf8;
    }

    var segments: std.ArrayList(Segment) = .empty;
    var nodes: std.ArrayList(Aside) = .empty;
    var diags: std.ArrayList(ParseDiag) = .empty;

    var cursor: usize = 0;
    while (cursor < body.len) {
        // Scan forward for next component open or Aside open.
        var i = cursor;
        var found_aside: ?usize = null;
        var found_unknown: ?struct { at: usize, name: []const u8 } = null;

        while (i < body.len) {
            if (body[i] != '<') {
                i += 1;
                continue;
            }

            if (isAsideOpenAt(body, i)) {
                found_aside = i;
                break;
            }

            if (componentOpenNameAt(body, i)) |name| {
                if (!isRegisteredComponent(name)) {
                    found_unknown = .{ .at = i, .name = name };
                    break;
                }
            }
            i += 1;
        }

        // Unregistered PascalCase component → hard diagnostic; keep the open
        // tag (and any self-close) as markdown so authors still see the text
        // while the build fails. Scanning continues for more errors.
        if (found_unknown) |u| {
            try appendDiag(
                &diags,
                arena,
                .unregistered_component,
                u.name,
                full_source,
                absOffset(body_start, u.at),
                "unregistered component tag (only Aside is built-in in v0.1)",
            );
            if (findOpenTagEnd(body, u.at)) |he| {
                // Include prose before the tag + the open tag itself as markdown.
                try segments.append(arena, .{ .markdown = body[cursor .. he + 1] });
                cursor = he + 1;
            } else {
                try segments.append(arena, .{ .markdown = body[cursor..] });
                break;
            }
            continue;
        }

        if (found_aside == null) {
            const rest = body[cursor..];
            if (rest.len > 0) {
                try segments.append(arena, .{ .markdown = rest });
            }
            break;
        }

        const start = found_aside.?;
        if (start > cursor) {
            try segments.append(arena, .{ .markdown = body[cursor..start] });
        }

        const abs_start = absOffset(body_start, start);
        const header_end = findOpenTagEnd(body, start) orelse {
            try appendDiag(
                &diags,
                arena,
                .malformed_attributes,
                registered_aside,
                full_source,
                abs_start,
                "Aside opening tag is missing a closing '>'",
            );
            // Do not swallow the remainder as a component body.
            try segments.append(arena, .{ .markdown = body[start..] });
            break;
        };

        const tag_header = body[start .. header_end + 1];
        const inner_start = header_end + 1;
        const lc = lineColAt(full_source, abs_start);
        const attrs = try parseAsideOpenAttrs(tag_header, &diags, arena, full_source, abs_start);

        if (isSelfClosing(tag_header)) {
            if (attrs.valid) {
                const node = Aside{
                    .kind = attrs.kind,
                    .id = attrs.id,
                    .body = "",
                    .raw_span = tag_header,
                    .line = lc.line,
                    .column = lc.column,
                };
                try nodes.append(arena, node);
                try segments.append(arena, .{ .aside = node });
            } else {
                // Invalid attrs: keep tag text as markdown; do not emit a component.
                try segments.append(arena, .{ .markdown = tag_header });
            }
            cursor = header_end + 1;
            continue;
        }

        // Close only at logical line start (optional spaces/tabs). Nested open
        // is unsupported and is a hard error when seen before that close.
        const scan = scanAsideClose(body, inner_start);
        if (scan.nested_open_at) |nested_at| {
            try appendDiag(
                &diags,
                arena,
                .nested_component,
                registered_aside,
                full_source,
                absOffset(body_start, nested_at),
                "nested Aside is not supported",
            );
        }

        const close_at = scan.close_at orelse {
            try appendDiag(
                &diags,
                arena,
                .unterminated_component,
                registered_aside,
                full_source,
                abs_start,
                "unterminated Aside: opening tag has no matching line-start </Aside>",
            );
            // Hard error: do not treat remainder as aside body.
            try segments.append(arena, .{ .markdown = body[start..] });
            break;
        };

        const span_end = close_at + close_aside.len;
        // Optional spaces/tabs before a line-start close are part of the close
        // recognition, not the component body.
        const inner_end = logicalLineStart(body, close_at);

        if (attrs.valid and scan.nested_open_at == null) {
            const node = Aside{
                .kind = attrs.kind,
                .id = attrs.id,
                .body = trimInnerNewlines(body[inner_start..inner_end]),
                .raw_span = body[start..span_end],
                .line = lc.line,
                .column = lc.column,
            };
            try nodes.append(arena, node);
            try segments.append(arena, .{ .aside = node });
        } else {
            // Attr / nesting errors: keep the whole span visible as markdown.
            try segments.append(arena, .{ .markdown = body[start..span_end] });
        }
        cursor = span_end;
    }

    // body_md: second lightweight pass over tokenized markdown segments only.
    const body_md = try joinMarkdownSegments(segments.items, arena);

    return .{
        .segments = try segments.toOwnedSlice(arena),
        .asides = try nodes.toOwnedSlice(arena),
        .body_md = body_md,
        .diagnostics = try diags.toOwnedSlice(arena),
    };
}

/// Convenience overload for tests / tools where the body is the full buffer.
pub fn parseBodySegmentsSimple(body: []const u8, arena: std.mem.Allocator) ParseError!BodyParseResult {
    return parseBodySegments(body, arena, body, 0);
}

fn joinMarkdownSegments(segments: []const Segment, arena: std.mem.Allocator) ![]const u8 {
    var total: usize = 0;
    for (segments) |seg| {
        switch (seg) {
            .markdown => |md| total += md.len,
            .aside => {},
        }
    }
    const cleaned = try arena.alloc(u8, total);
    var off: usize = 0;
    for (segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                @memcpy(cleaned[off .. off + md.len], md);
                off += md.len;
            },
            .aside => {},
        }
    }
    return cleaned;
}

/// Extract asides + stripped body (for tests / tools).
pub fn extractAsides(body: []const u8, arena: std.mem.Allocator) ParseError!struct { []const u8, []const Aside } {
    const r = try parseBodySegmentsSimple(body, arena);
    if (r.hasErrors()) {
        // Map first diagnostic to a typed error for simple call sites.
        for (r.diagnostics) |d| {
            switch (d.kind) {
                .unterminated_component => return error.UnterminatedComponent,
                .unregistered_component => return error.UnregisteredComponent,
                .malformed_attributes,
                .invalid_kind,
                .invalid_id,
                .duplicate_attribute,
                .unknown_attribute,
                .nested_component,
                => return error.MalformedAttributes,
                .unclosed_frontmatter => return error.UnclosedFrontmatter,
                .value_too_long, .frontmatter_limit => return error.FrontmatterValueTooLong,
                .duplicate_key,
                .malformed_line,
                .unsupported_syntax,
                .unknown_key,
                .empty_value,
                .bad_quote,
                => return error.MalformedAttributes,
            }
        }
    }
    return .{ r.body_md, r.asides };
}

/// Rebuild a single markdown body with asides inlined as directive-style blocks.
/// Used by RAG so callout text stays on the page segment (no separate files).
pub fn bodyWithAsidesInline(segments: []const Segment, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (segments) |seg| {
        switch (seg) {
            .markdown => |md| try out.appendSlice(arena, md),
            .aside => |a| {
                const kind = if (a.kind.len > 0) a.kind else "note";
                try out.appendSlice(arena, "\n\n:::");
                try out.appendSlice(arena, kind);
                if (a.id.len > 0) {
                    try out.appendSlice(arena, "{id=\"");
                    try out.appendSlice(arena, a.id);
                    try out.appendSlice(arena, "\"}");
                }
                try out.append(arena, '\n');
                try out.appendSlice(arena, a.body);
                try out.appendSlice(arena, "\n:::\n\n");
            },
        }
    }
    return try out.toOwnedSlice(arena);
}

/// Full pre-render parse of a page's raw source.
///
/// - Empty files: no frontmatter, empty body — valid.
/// - Unclosed `---` fence: `error.UnclosedFrontmatter` (does not swallow file).
/// - UTF-8 BOM: `error.Utf8Bom` (rejected, never stripped).
/// - Non-UTF-8: `error.InvalidUtf8` before any frontmatter/component scan.
/// - Oversize / illegal frontmatter values: diagnostics; values not stored.
///
/// Frontmatter string fields on the result are slices into `source`. Do **not**
/// put them on PageDb without duping (see `compile.promoteFrontmatter`).
pub fn parsePageSource(source: []const u8, arena: std.mem.Allocator) ParseError!ParsedPage {
    // Encoding gate: BOM rejected; invalid UTF-8 rejected. Both before tokenization.
    if (source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
        return error.Utf8Bom;
    }
    if (source.len > 0 and !std.unicode.utf8ValidateSlice(source)) {
        return error.InvalidUtf8;
    }
    const fm_result = try parseFrontmatter(source, arena);
    const body_start = fm_result[1];
    const body = source[body_start..];
    const segs = try parseBodySegments(body, arena, source, body_start);

    // Merge frontmatter length diagnostics with body/component diagnostics.
    const all_diags: []const ParseDiag = if (fm_result[2].len == 0)
        segs.diagnostics
    else if (segs.diagnostics.len == 0)
        fm_result[2]
    else blk: {
        var merged: std.ArrayList(ParseDiag) = .empty;
        try merged.appendSlice(arena, fm_result[2]);
        try merged.appendSlice(arena, segs.diagnostics);
        break :blk try merged.toOwnedSlice(arena);
    };

    return .{
        .frontmatter = fm_result[0],
        .segments = segs.segments,
        .asides = segs.asides,
        .body_md = segs.body_md,
        .diagnostics = all_diags,
    };
}

/// Apply parse results onto an existing Page (paths/metadata only — no components).
///
/// **Does not** assign `frontmatter` from document-arena slices. Callers that
/// need PageDb-owned metadata must run `compile.promoteFrontmatter` (or
/// equivalent dupe) before any whiteboard/`doc_arena` reset.
pub fn ingestIntoPage(p: *Page, source: []const u8, arena: std.mem.Allocator) ParseError!void {
    // raw_source only when caller already owns `source` for PageDb lifetime.
    p.raw_source = source;
    const parsed = try parsePageSource(source, arena);
    if (parsed.hasErrors()) return error.UnregisteredComponent;
    // Intentionally leave p.frontmatter defaulted — never alias parse slices.
    p.body_md = parsed.body_md;
}

/// Format a diagnostic for stderr (compile / RAG tooling).
pub fn formatDiag(d: ParseDiag, source_path: []const u8, buf: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    const code: []const u8 = switch (d.kind) {
        .value_too_long, .empty_value, .bad_quote => "E_FRONTMATTER_VALUE",
        .duplicate_key => "E_FRONTMATTER_DUP_KEY",
        .unclosed_frontmatter,
        .frontmatter_limit,
        .malformed_line,
        .unsupported_syntax,
        .unknown_key,
        => "E_FRONTMATTER",
        .unregistered_component,
        .unterminated_component,
        .malformed_attributes,
        .invalid_kind,
        .invalid_id,
        .duplicate_attribute,
        .unknown_attribute,
        .nested_component,
        => "E_COMPONENT",
    };
    try buf.appendSlice(gpa, "error: ");
    try buf.appendSlice(gpa, code);
    try buf.appendSlice(gpa, ": ");
    if (source_path.len > 0) {
        try buf.appendSlice(gpa, source_path);
        try buf.append(gpa, ':');
        try buf.print(gpa, "{d}:{d}: ", .{ d.line, d.column });
    }
    if (d.component_name.len > 0) {
        try buf.appendSlice(gpa, d.component_name);
        try buf.appendSlice(gpa, ": ");
    }
    try buf.appendSlice(gpa, d.message);
}

// ---------------------------------------------------------------------------
// Tests — frontmatter grammar
// ---------------------------------------------------------------------------

test "empty file: no frontmatter, valid" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = try parsePageSource("", arena.allocator());
    try std.testing.expect(!p.hasErrors());
    try std.testing.expect(p.frontmatter.title == null);
    try std.testing.expectEqual(@as(usize, 0), p.body_md.len);
}

test "no frontmatter: body starts at offset 0" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter("# Just a page\n", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result[1]);
    try std.testing.expectEqual(@as(usize, 0), result[2].len);
    try std.testing.expect(result[0].title == null);
}

test "parse frontmatter parentEntry LF" {
    const src =
        \\---
        \\title: Tip Sheet
        \\parentEntry: guides/intro
        \\---
        \\# Hello
        \\
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expectEqualStrings("Tip Sheet", result[0].title.?);
    try std.testing.expectEqualStrings("guides/intro", result[0].parent_entry.?);
    try std.testing.expect(result[0].isSatellite());
    try std.testing.expectEqual(@as(usize, 0), result[2].len);
}

test "parse frontmatter accepts CRLF and compiler-dialect parent" {
    const src = "---\r\ntitle: Tip Sheet\r\nparent: guides/intro\r\n---\r\n# Hello\r\n";
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expectEqualStrings("Tip Sheet", result[0].title.?);
    try std.testing.expectEqualStrings("guides/intro", result[0].parent_entry.?);
    try std.testing.expectEqual(@as(usize, 0), result[2].len);
    // Body starts after closing fence newline.
    try std.testing.expect(std.mem.startsWith(u8, src[result[1]..], "# Hello"));
}

test "unclosed frontmatter fence is hard error" {
    const src =
        \\---
        \\title: Orphan
        \\# never closed
        \\body that would be lost if swallowed
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    try std.testing.expectError(error.UnclosedFrontmatter, parsePageSource(src, arena.allocator()));
    try std.testing.expectError(error.UnclosedFrontmatter, parseFrontmatter(src, arena.allocator()));
}

test "invalid utf8 is hard error before frontmatter" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bad = [_]u8{ 0x48, 0x69, 0x20, 0xFF, 0xFE }; // "Hi " + invalid
    try std.testing.expectError(error.InvalidUtf8, parsePageSource(&bad, arena.allocator()));
}

test "utf8 BOM is rejected not stripped" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const with_bom = [_]u8{ 0xEF, 0xBB, 0xBF, '-', '-', '-', '\n', 't', 'i', 't', 'l', 'e', ':', ' ', 'X', '\n', '-', '-', '-', '\n' };
    try std.testing.expectError(error.Utf8Bom, parsePageSource(&with_bom, arena.allocator()));
}

test "duplicate title is hard diagnostic" {
    const src =
        \\---
        \\title: A
        \\title: B
        \\---
        \\
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), result[2].len);
    try std.testing.expect(result[2][0].kind == .duplicate_key);
    try std.testing.expectEqualStrings("A", result[0].title.?);
    try std.testing.expect(result[2][0].line >= 3);
}

test "duplicate parentEntry is hard diagnostic" {
    const src =
        \\---
        \\parentEntry: a
        \\parentEntry: b
        \\---
        \\
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expect(result[2].len >= 1);
    try std.testing.expect(result[2][0].kind == .duplicate_key);
    try std.testing.expectEqualStrings("a", result[0].parent_entry.?);
}

test "parentEntry plus parent_entry is hard duplicate-key error" {
    const src =
        \\---
        \\parentEntry: guides/intro
        \\parent_entry: guides/other
        \\---
        \\
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), result[2].len);
    try std.testing.expect(result[2][0].kind == .duplicate_key);
    try std.testing.expect(std.mem.indexOf(u8, result[2][0].message, "parent_entry") != null);
    try std.testing.expect(std.mem.indexOf(u8, result[2][0].message, "parentEntry") != null);
    // First wins for the stored value; second is the diagnostic site.
    try std.testing.expectEqualStrings("guides/intro", result[0].parent_entry.?);
}

test "parent plus parentEntry is hard duplicate-key error" {
    const src =
        \\---
        \\parent: guides/intro
        \\parentEntry: guides/other
        \\---
        \\
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try parseFrontmatter(src, arena.allocator());
    try std.testing.expect(result[2][0].kind == .duplicate_key);
}

test "parseFrontmatter rejects oversize title without promoting it" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const huge_len: usize = 10_000;
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "---\ntitle: ");
    try src.appendNTimes(a, 'A', huge_len);
    try src.appendSlice(a, "\n---\n\nbody\n");

    const result = try parseFrontmatter(src.items, a);
    try std.testing.expect(result[0].title == null);
    try std.testing.expectEqual(@as(usize, 1), result[2].len);
    try std.testing.expect(result[2][0].kind == .value_too_long);
    try std.testing.expect(std.mem.indexOf(u8, result[2][0].message, "512") != null);

    const page = try parsePageSource(src.items, a);
    try std.testing.expect(page.hasErrors());
    try std.testing.expect(page.frontmatter.title == null);
    var saw = false;
    for (page.diagnostics) |d| {
        if (d.kind == .value_too_long) saw = true;
    }
    try std.testing.expect(saw);
}

test "parseFrontmatter rejects oversize parent entity id" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "---\nparentEntry: ");
    try src.appendNTimes(a, 'p', page_mod.max_entity_id_bytes + 1);
    try src.appendSlice(a, "\n---\n");

    const result = try parseFrontmatter(src.items, a);
    try std.testing.expect(result[0].parent_entry == null);
    try std.testing.expectEqual(@as(usize, 1), result[2].len);
    try std.testing.expect(result[2][0].kind == .value_too_long);
}

test "parseFrontmatter rejects oversize frontmatter block" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "---\ntitle: ");
    // Blow past max_frontmatter_bytes with padding inside the block.
    try src.appendNTimes(a, 'x', max_frontmatter_bytes + 8);
    try src.appendSlice(a, "\n---\n");

    const result = try parseFrontmatter(src.items, a);
    try std.testing.expect(result[0].title == null);
    var saw_limit = false;
    for (result[2]) |d| {
        if (d.kind == .frontmatter_limit) saw_limit = true;
    }
    try std.testing.expect(saw_limit);
}

test "unsupported YAML-looking forms are rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_]struct { src: []const u8, kind: ParseDiag.Kind }{
        .{ .src = "---\ntitle:\n  en: Hello\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\ntitle: |\n  multi\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\ntitle: >\n  folded\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\nmap: {a: 1}\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\ntitle: [not, allowed]\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\nanchor: &name val\n---\n", .kind = .unsupported_syntax },
        .{ .src = "---\n- item\n---\n", .kind = .unsupported_syntax },
    };
    for (cases) |c| {
        // Some cases are unclosed (multiline YAML) — accept UnclosedFrontmatter
        // or diagnostic unsupported_syntax / unknown_key.
        const result = parseFrontmatter(c.src, a) catch |err| {
            try std.testing.expect(err == error.UnclosedFrontmatter);
            continue;
        };
        var saw = false;
        for (result[2]) |d| {
            if (d.kind == c.kind or d.kind == .unknown_key or d.kind == .empty_value or d.kind == .malformed_line)
                saw = true;
        }
        try std.testing.expect(saw);
    }
}

test "quoted and colon-containing values follow grammar" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Plain value may contain colons after the first key separator.
    {
        const result = try parseFrontmatter("---\ntitle: Foo: Bar\n---\n", a);
        try std.testing.expectEqual(@as(usize, 0), result[2].len);
        try std.testing.expectEqualStrings("Foo: Bar", result[0].title.?);
    }
    // Double-quoted value.
    {
        const result = try parseFrontmatter("---\ntitle: \"Hello World\"\n---\n", a);
        try std.testing.expectEqual(@as(usize, 0), result[2].len);
        try std.testing.expectEqualStrings("Hello World", result[0].title.?);
    }
    // Double-quoted with colon inside.
    {
        const result = try parseFrontmatter("---\ntitle: \"a:b\"\n---\n", a);
        try std.testing.expectEqualStrings("a:b", result[0].title.?);
    }
    // Single quotes rejected.
    {
        const result = try parseFrontmatter("---\ntitle: 'nope'\n---\n", a);
        try std.testing.expect(result[0].title == null);
        try std.testing.expect(result[2][0].kind == .bad_quote);
    }
    // Unclosed double quote rejected.
    {
        const result = try parseFrontmatter("---\ntitle: \"open\n---\n", a);
        try std.testing.expect(result[0].title == null);
        try std.testing.expect(result[2][0].kind == .bad_quote);
    }
    // Empty value rejected.
    {
        const result = try parseFrontmatter("---\ntitle:\n---\n", a);
        try std.testing.expect(result[0].title == null);
        try std.testing.expect(result[2][0].kind == .empty_value);
    }
    // Empty double quotes rejected.
    {
        const result = try parseFrontmatter("---\ntitle: \"\"\n---\n", a);
        try std.testing.expect(result[0].title == null);
        try std.testing.expect(result[2][0].kind == .empty_value);
    }
}

test "unknown key is diagnostic; id status tags are recognized" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    {
        const result = try parseFrontmatter("---\ncategory: x\n---\n", a);
        try std.testing.expect(result[2][0].kind == .unknown_key);
    }
    {
        const result = try parseFrontmatter("---\nid: guides/intro\ntitle: X\nstatus: published\ntags: [a, b]\n---\n", a);
        try std.testing.expectEqual(@as(usize, 0), result[2].len);
        try std.testing.expectEqual(@as(usize, 1), result[0].extras.len);
        try std.testing.expectEqualStrings("id", result[0].extras[0].key);
        try std.testing.expectEqualStrings("guides/intro", result[0].extras[0].value);
    }
    {
        const result = try parseFrontmatter("---\ntags: nope\n---\n", a);
        try std.testing.expect(result[2][0].kind == .unsupported_syntax);
    }
}

test "tags flow list is deliberately supported; other flow forms rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    {
        const result = try parseFrontmatter("---\ntags: [guide, intro]\n---\n", a);
        try std.testing.expectEqual(@as(usize, 0), result[2].len);
    }
    {
        const result = try parseFrontmatter("---\ntitle: [not, a, title]\n---\n", a);
        try std.testing.expect(result[2][0].kind == .unsupported_syntax);
    }
}

test "opening fence only at byte zero column zero" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Leading space → not frontmatter; body includes the whole file.
    const result = try parseFrontmatter(" ---\ntitle: X\n---\n", arena.allocator());
    try std.testing.expectEqual(@as(usize, 0), result[1]);
    try std.testing.expect(result[0].title == null);
}

test "formatDiag includes path line column for frontmatter" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try formatDiag(.{
        .kind = .duplicate_key,
        .line = 3,
        .column = 1,
        .message = "duplicate frontmatter key \"title\"",
    }, "guides/x.md", &buf, gpa);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "guides/x.md:3:1:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "E_FRONTMATTER_DUP_KEY") != null);
}

// ---------------------------------------------------------------------------
// Tests — components / body
// ---------------------------------------------------------------------------

test "extract Aside zero-copy + strip" {
    const body =
        \\Intro text.
        \\
        \\<Aside kind="tip" id="006-1">
        \\Remember to hydrate.
        \\</Aside>
        \\
        \\Outro text.
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const result = try extractAsides(body, arena.allocator());
    const cleaned = result[0];
    const nodes = result[1];
    try std.testing.expectEqual(@as(usize, 1), nodes.len);
    try std.testing.expectEqualStrings("tip", nodes[0].kind);
    try std.testing.expectEqualStrings("006-1", nodes[0].id);
    try std.testing.expectEqualStrings("Remember to hydrate.", nodes[0].body);
    try std.testing.expect(@intFromPtr(nodes[0].body.ptr) >= @intFromPtr(body.ptr));
    try std.testing.expect(@intFromPtr(nodes[0].body.ptr) < @intFromPtr(body.ptr) + body.len);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "<Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Intro text.") != null);
    try std.testing.expect(std.mem.indexOf(u8, cleaned, "Outro text.") != null);
}

test "ordered segments preserve document order" {
    const body =
        \\Before.
        \\<Aside kind="tip" id="a">
        \\A
        \\</Aside>
        \\Middle.
        \\<Aside kind="warning" id="b">
        \\B
        \\</Aside>
        \\After.
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 5), r.segments.len);
    try std.testing.expect(r.segments[0] == .markdown);
    try std.testing.expect(r.segments[1] == .aside);
    try std.testing.expectEqualStrings("a", r.segments[1].aside.id);
    try std.testing.expect(r.segments[2] == .markdown);
    try std.testing.expect(r.segments[3] == .aside);
    try std.testing.expectEqualStrings("warning", r.segments[3].aside.kind);
    try std.testing.expect(r.segments[4] == .markdown);
    try std.testing.expectEqual(@as(usize, 2), r.asides.len);
}

test "unquoted attrs and single quotes; legacy type= alias" {
    const body =
        \\<Aside type=note id='x-1'>
        \\hi
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expectEqualStrings("note", r.asides[0].kind);
    try std.testing.expectEqualStrings("x-1", r.asides[0].id);
    try std.testing.expectEqualStrings("hi", r.asides[0].body);
}

test "AsideFoo lexical boundary is not Aside" {
    const body = "Talk about <AsideFoo> nonsense and real tags later.\n";
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    // AsideFoo is a single long PascalCase name → unregistered, not Aside.
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
    try std.testing.expectEqual(ParseDiag.Kind.unregistered_component, r.diagnostics[0].kind);
    try std.testing.expectEqualStrings("AsideFoo", r.diagnostics[0].component_name);
    try std.testing.expect(std.mem.indexOf(u8, r.body_md, "AsideFoo") != null);
}

test "full page parse strips aside from body_md" {
    const src =
        \\---
        \\title: T
        \\---
        \\# Hi
        \\
        \\<Aside kind="tip" id="1">
        \\secret
        \\</Aside>
        \\
        \\End.
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = try parsePageSource(src, arena.allocator());
    try std.testing.expect(!p.hasErrors());
    try std.testing.expectEqualStrings("T", p.frontmatter.title.?);
    try std.testing.expectEqual(@as(usize, 1), p.asides.len);
    try std.testing.expectEqualStrings("secret", p.asides[0].body);
    try std.testing.expect(std.mem.indexOf(u8, p.body_md, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.body_md, "Aside") == null);
    try std.testing.expect(std.mem.indexOf(u8, p.body_md, "# Hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, p.body_md, "End.") != null);
}

test "bodyWithAsidesInline keeps callout text on page" {
    const body =
        \\Hello.
        \\<Aside kind="tip" id="t1">
        \\Drink water.
        \\</Aside>
        \\Bye.
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    const joined = try bodyWithAsidesInline(r.segments, arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, joined, ":::tip{id=\"t1\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Drink water.") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined, "Hello.") != null);
}

test "unterminated Aside is hard error not body swallow" {
    const body =
        \\Before.
        \\<Aside kind="tip">
        \\orphaned forever
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(ParseDiag.Kind.unterminated_component, r.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "unterminated") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "line-start") != null);
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
    // Remainder kept as markdown (visible), not as aside body.
    try std.testing.expect(std.mem.indexOf(u8, r.body_md, "orphaned forever") != null);
}

test "same-line close does not terminate Aside" {
    // Preferred close rule: only line-start </Aside> (optional spaces/tabs).
    const body =
        \\<Aside kind="tip" id="inline">
        \\body with mid-line </Aside> still open
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expect(std.mem.indexOf(u8, r.asides[0].body, "mid-line </Aside> still open") != null);
}

test "close tag with leading spaces or tabs is accepted" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Spaces only (multiline string).
    {
        const body =
            \\<Aside kind="info" id="pad">
            \\padded close
            \\   </Aside>
        ;
        const r = try parseBodySegmentsSimple(body, a);
        try std.testing.expect(!r.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), r.asides.len);
        try std.testing.expectEqualStrings("padded close", r.asides[0].body);
    }
    // Leading tab before close (constructed; Zig \\ strings cannot contain tabs).
    {
        const body = try std.fmt.allocPrint(a, "<Aside kind=\"info\" id=\"pad2\">\npadded tab\n\t</Aside>\n", .{});
        const r = try parseBodySegmentsSimple(body, a);
        try std.testing.expect(!r.hasErrors());
        try std.testing.expectEqual(@as(usize, 1), r.asides.len);
        try std.testing.expectEqualStrings("padded tab", r.asides[0].body);
    }
}

test "unregistered Figure is hard diagnostic with line col" {
    const src =
        \\---
        \\title: T
        \\---
        \\Hello
        \\<Figure src="x.png"></Figure>
        \\Done.
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const p = try parsePageSource(src, arena.allocator());
    try std.testing.expect(p.hasErrors());
    try std.testing.expectEqual(ParseDiag.Kind.unregistered_component, p.diagnostics[0].kind);
    try std.testing.expectEqualStrings("Figure", p.diagnostics[0].component_name);
    try std.testing.expect(p.diagnostics[0].line >= 4);
    try std.testing.expect(p.diagnostics[0].column >= 1);
    try std.testing.expectEqual(@as(usize, 0), p.asides.len);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try formatDiag(p.diagnostics[0], "page.md", &buf, gpa);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "page.md:") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "Figure") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "E_COMPONENT") != null);
}

test "nested Aside is unsupported hard error" {
    const body =
        \\<Aside kind="tip" id="outer">
        \\outer
        \\<Aside kind="note" id="inner">
        \\inner
        \\</Aside>
        \\still outer?
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
    var saw_nested = false;
    for (r.diagnostics) |d| {
        if (d.kind == .nested_component) {
            saw_nested = true;
            try std.testing.expect(std.mem.indexOf(u8, d.message, "nested") != null);
        }
    }
    try std.testing.expect(saw_nested);
}

test "duplicate kind attribute is hard error" {
    const body =
        \\<Aside kind="tip" kind="note" id="d1">
        \\x
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
    try std.testing.expectEqual(ParseDiag.Kind.duplicate_attribute, r.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "kind") != null);
}

test "duplicate id attribute is hard error" {
    const body =
        \\<Aside kind="tip" id="a" id="b">
        \\x
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(ParseDiag.Kind.duplicate_attribute, r.diagnostics[0].kind);
    try std.testing.expect(std.mem.indexOf(u8, r.diagnostics[0].message, "id") != null);
}

test "invalid Aside kind is hard error" {
    const body =
        \\<Aside kind="sparkle" id="k1">
        \\nope
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(ParseDiag.Kind.invalid_kind, r.diagnostics[0].kind);
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
}

test "id with quotes or special characters is rejected" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cases = [_][]const u8{
        \\<Aside kind="tip" id='a"b'>
        \\x
        \\</Aside>
        ,
        \\<Aside kind="tip" id="a b">
        \\x
        \\</Aside>
        ,
        \\<Aside kind="tip" id="a}b">
        \\x
        \\</Aside>
        ,
        \\<Aside kind="tip" id="a<b">
        \\x
        \\</Aside>
        ,
        \\<Aside kind="tip" id="">
        \\x
        \\</Aside>
        ,
    };
    for (cases) |body| {
        const r = try parseBodySegmentsSimple(body, a);
        try std.testing.expect(r.hasErrors());
        try std.testing.expectEqual(@as(usize, 0), r.asides.len);
        var saw_id = false;
        for (r.diagnostics) |d| {
            if (d.kind == .invalid_id) saw_id = true;
        }
        try std.testing.expect(saw_id);
    }
}

test "safe id grammar accepts alnum underscore hyphen" {
    try std.testing.expect(isSafeAsideId("006-1"));
    try std.testing.expect(isSafeAsideId("rag-cli-flags"));
    try std.testing.expect(isSafeAsideId("A_b9"));
    try std.testing.expect(!isSafeAsideId(""));
    try std.testing.expect(!isSafeAsideId("-lead"));
    try std.testing.expect(!isSafeAsideId("has space"));
    try std.testing.expect(!isSafeAsideId("a\"b"));
}

test "literal line-start close inside fence terminates per close rule" {
    // Fences are not a second grammar: line-start </Aside> still closes.
    const body =
        \\<Aside kind="tip" id="fence">
        \\```
        \\</Aside>
        \\```
        \\trailing
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expectEqualStrings("```", r.asides[0].body);
    // After early close, remaining fence/close text is markdown (may include
    // a stray line-start </Aside> as prose).
    try std.testing.expect(std.mem.indexOf(u8, r.body_md, "trailing") != null);
}

test "mid-line literal close in example does not terminate" {
    const body =
        \\<Aside kind="tip" id="doc">
        \\Example: write `</Aside>` mid-line in docs.
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expect(std.mem.indexOf(u8, r.asides[0].body, "`</Aside>`") != null);
}

test "unknown Aside attribute is hard error" {
    const body =
        \\<Aside kind="tip" class="x" id="u1">
        \\x
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqual(ParseDiag.Kind.unknown_attribute, r.diagnostics[0].kind);
}

test "Broside is not a registered component" {
    const body = "<Broside type=\"tip\">legacy</Broside>\n";
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expectEqualStrings("Broside", r.diagnostics[0].component_name);
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
}

test "body_md derived from segments not second raw scan" {
    const body =
        \\A
        \\<Aside kind="tip">
        \\X
        \\</Aside>
        \\B
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    const joined = try joinMarkdownSegments(r.segments, arena.allocator());
    try std.testing.expectEqualStrings(joined, r.body_md);
}

test "Aside line column recorded on node" {
    const body =
        \\line1
        \\<Aside kind="tip">
        \\x
        \\</Aside>
    ;
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try parseBodySegmentsSimple(body, arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expectEqual(@as(u32, 2), r.asides[0].line);
    try std.testing.expectEqual(@as(u32, 1), r.asides[0].column);
}

test "parseBodySegments rejects invalid utf8" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const bad = [_]u8{ '<', 'A', 's', 'i', 'd', 'e', ' ', 0xFF };
    try std.testing.expectError(error.InvalidUtf8, parseBodySegmentsSimple(&bad, arena.allocator()));
}


