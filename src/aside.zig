//! Aside component tokenizer + HTML rendering (milestone 10).
//!
//! ## Authoring
//!
//! The supported components are constrained `<Aside …>…</Aside>` and
//! `<Details …>…</Details>`.
//! Unknown PascalCase open tags are hard errors. This is **not** generic HTML
//! parsing, **not** MDX, and **not** a multi-component registry system.
//!
//! ## Recognition rules
//!
//! - Components are recognized **only outside** fenced code blocks
//!   (``` / ~~~ CommonMark-style fences).
//! - Literal `<Aside>` / `</Aside>` text inside fences stays literal.
//! - Close tag `</Aside>` is recognized only at **logical line start**
//!   (optional ASCII spaces/tabs). Mid-line `</Aside>` does not close.
//! - Nested Aside is rejected with a stable diagnostic.
//! - Document order is preserved; asides never become graph nodes or pages.
//!
//! ## RAG export representation
//!
//! Parsed asides may be emitted as `:::kind` / `:::kind{id="…"}` blocks for
//! retrieval. That form is **export-only** and **not** round-trippable source.

const std = @import("std");
const apex = @import("apex.zig");

// ---------------------------------------------------------------------------
// Bounds / allowlists
// ---------------------------------------------------------------------------

/// Max bytes for optional component `id` attribute values.
pub const max_aside_id_bytes: usize = 64;
/// Max bytes for a plain-text Details `summary` attribute value.
pub const max_details_summary_bytes: usize = 256;

/// Closed kind vocabulary (exact spellings, lowercase).
pub const allowed_kinds = [_][]const u8{ "note", "tip", "info", "warning", "danger" };

pub fn isAllowedKind(kind: []const u8) bool {
    for (allowed_kinds) |k| {
        if (std.mem.eql(u8, k, kind)) return true;
    }
    return false;
}

/// Safe-anchor grammar for optional `id`:
///   `[A-Za-z0-9][A-Za-z0-9_-]*` length 1…64
pub fn isValidAsideId(id: []const u8) bool {
    if (id.len == 0 or id.len > max_aside_id_bytes) return false;
    const c0 = id[0];
    const ok0 = (c0 >= 'A' and c0 <= 'Z') or
        (c0 >= 'a' and c0 <= 'z') or
        (c0 >= '0' and c0 <= '9');
    if (!ok0) return false;
    for (id[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Details summaries are source text, not Markdown. Newlines would make the
/// opening tag multi-line, so they are rejected along with empty values.
pub fn isValidDetailsSummary(summary: []const u8) bool {
    if (summary.len == 0 or summary.len > max_details_summary_bytes) return false;
    for (summary) |c| if (c == '\n' or c == '\r') return false;
    return true;
}

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// Structured callout extracted from `<Aside kind="…" id="…">…</Aside>`.
/// String fields are slices into the parent page body/source (zero-copy).
pub const Aside = struct {
    /// Semantic kind from allowlist (default `"note"` when attribute omitted).
    kind: []const u8 = "note",
    /// Optional stable in-page anchor (empty when omitted).
    id: []const u8 = "",
    /// Inner markdown between open and close tags (slice into source).
    body: []const u8 = "",
    /// Full span of the original tag in source, for diagnostics.
    raw_span: []const u8 = "",
    /// 1-based line of the opening tag within the scanned buffer.
    line: u32 = 1,
    /// 1-based byte column of the opening tag within its line.
    column: u32 = 1,
};

/// Structured disclosure extracted from `<Details summary="…">…</Details>`.
pub const Details = struct {
    summary: []const u8,
    id: []const u8 = "",
    open: bool = false,
    body: []const u8 = "",
    raw_span: []const u8 = "",
    line: u32 = 1,
    column: u32 = 1,
};

pub const Segment = union(enum) {
    markdown: []const u8,
    aside: Aside,
    details: Details,
};

/// Component-local diagnostic kinds (stable for tests; map to `ECOMPONENT` in pipeline).
pub const DiagKind = enum {
    unregistered_component,
    unterminated_component,
    nested_component,
    invalid_kind,
    invalid_id,
    invalid_summary,
    invalid_open,
    duplicate_attribute,
    unknown_attribute,
    unterminated_quote,
    malformed_attribute,
    missing_close_angle,
};

pub const Diagnostic = struct {
    kind: DiagKind,
    /// 1-based line within the scanned buffer (body-relative for body-only scans).
    line: u32 = 1,
    /// 1-based byte column within the line.
    column: u32 = 1,
    /// Static or arena-owned message.
    message: []const u8,
    /// Component name when relevant (e.g. `Figure`), else empty.
    name: []const u8 = "",
};

pub const TokenizeResult = struct {
    segments: []const Segment = &.{},
    asides: []const Aside = &.{},
    details: []const Details = &.{},
    diagnostics: []const Diagnostic = &.{},

    pub fn hasErrors(self: TokenizeResult) bool {
        return self.diagnostics.len > 0;
    }
};

// ---------------------------------------------------------------------------
// Line / position helpers
// ---------------------------------------------------------------------------

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn lineColAt(source: []const u8, index: usize) struct { u32, u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < index and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }
    }
    return .{ line, col };
}

fn atLineStart(source: []const u8, index: usize) bool {
    if (index == 0) return true;
    return source[index - 1] == '\n';
}

/// Detect open/close fence at `index` when `index` is a line start.
/// Returns fence marker char (` or ~) and run length, or null.
fn fenceAtLineStart(source: []const u8, index: usize) ?struct { u8, usize } {
    if (!atLineStart(source, index)) return null;
    var i = index;
    // Optional indent up to 3 spaces (CommonMark).
    var spaces: usize = 0;
    while (i < source.len and source[i] == ' ' and spaces < 3) : ({
        i += 1;
        spaces += 1;
    }) {}
    if (i >= source.len) return null;
    const ch = source[i];
    if (ch != '`' and ch != '~') return null;
    var run: usize = 0;
    while (i + run < source.len and source[i + run] == ch) : (run += 1) {}
    if (run < 3) return null;
    // Info string may follow; we only need the marker.
    return .{ ch, run };
}

fn lineEndIndex(source: []const u8, start: usize) usize {
    var i = start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    return i;
}

/// True when `name` is PascalCase component-like: starts with A–Z, continues
/// with [A-Za-z0-9_-].
fn isPascalComponentName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] < 'A' or name[0] > 'Z') return false;
    for (name[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

/// Lexical boundary after `<Aside` / `<Figure`: next must be whitespace, `/`, or `>`.
fn tagNameBoundaryOk(source: []const u8, after_name: usize) bool {
    if (after_name >= source.len) return true;
    const c = source[after_name];
    return isSpace(c) or c == '/' or c == '>' or c == '\n' or c == '\r';
}

// ---------------------------------------------------------------------------
// Attribute parse
// ---------------------------------------------------------------------------

const AttrError = error{
    DuplicateAttribute,
    UnknownAttribute,
    UnterminatedQuote,
    MalformedAttribute,
    InvalidKind,
    InvalidId,
    InvalidSummary,
    InvalidOpen,
};

const ParsedAttrs = struct {
    kind: []const u8 = "note",
    id: []const u8 = "",
    saw_kind: bool = false,
    saw_id: bool = false,
};

const ParsedDetailsAttrs = struct {
    summary: []const u8 = "",
    id: []const u8 = "",
    open: bool = false,
    saw_summary: bool = false,
    saw_id: bool = false,
    saw_open: bool = false,
};

fn parseAttributes(open_inner: []const u8) AttrError!ParsedAttrs {
    var attrs: ParsedAttrs = .{};
    var i: usize = 0;
    while (i < open_inner.len) {
        while (i < open_inner.len and (isSpace(open_inner[i]) or open_inner[i] == '\n' or open_inner[i] == '\r')) : (i += 1) {}
        if (i >= open_inner.len) break;

        const key_start = i;
        while (i < open_inner.len) {
            const c = open_inner[i];
            const ok = (c >= 'A' and c <= 'Z') or
                (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or
                c == '_' or c == '-';
            if (!ok) break;
            i += 1;
        }
        if (i == key_start) return error.MalformedAttribute;
        const key = open_inner[key_start..i];

        while (i < open_inner.len and isSpace(open_inner[i])) : (i += 1) {}
        if (i >= open_inner.len or open_inner[i] != '=') return error.MalformedAttribute;
        i += 1;
        while (i < open_inner.len and isSpace(open_inner[i])) : (i += 1) {}
        if (i >= open_inner.len or open_inner[i] != '"') {
            // Quoted values only.
            return error.MalformedAttribute;
        }
        i += 1; // opening "
        const val_start = i;
        while (i < open_inner.len and open_inner[i] != '"') : (i += 1) {}
        if (i >= open_inner.len) return error.UnterminatedQuote;
        const val = open_inner[val_start..i];
        i += 1; // closing "

        if (std.mem.eql(u8, key, "kind") or std.mem.eql(u8, key, "type")) {
            // `type` is a legacy alias for `kind` (same allowlist / same slot).
            if (attrs.saw_kind) return error.DuplicateAttribute;
            attrs.saw_kind = true;
            if (!isAllowedKind(val)) return error.InvalidKind;
            attrs.kind = val;
        } else if (std.mem.eql(u8, key, "id")) {
            if (attrs.saw_id) return error.DuplicateAttribute;
            attrs.saw_id = true;
            if (!isValidAsideId(val)) return error.InvalidId;
            attrs.id = val;
        } else {
            return error.UnknownAttribute;
        }
    }
    return attrs;
}

fn parseDetailsAttributes(open_inner: []const u8) AttrError!ParsedDetailsAttrs {
    var attrs: ParsedDetailsAttrs = .{};
    var i: usize = 0;
    while (i < open_inner.len) {
        while (i < open_inner.len and (isSpace(open_inner[i]) or open_inner[i] == '\n' or open_inner[i] == '\r')) : (i += 1) {}
        if (i >= open_inner.len) break;
        const key_start = i;
        while (i < open_inner.len) {
            const c = open_inner[i];
            const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '_' or c == '-';
            if (!ok) break;
            i += 1;
        }
        if (i == key_start) return error.MalformedAttribute;
        const key = open_inner[key_start..i];
        while (i < open_inner.len and isSpace(open_inner[i])) : (i += 1) {}
        if (i >= open_inner.len or open_inner[i] != '=') return error.MalformedAttribute;
        i += 1;
        while (i < open_inner.len and isSpace(open_inner[i])) : (i += 1) {}
        if (i >= open_inner.len or open_inner[i] != '"') return error.MalformedAttribute;
        i += 1;
        const val_start = i;
        while (i < open_inner.len and open_inner[i] != '"') : (i += 1) {}
        if (i >= open_inner.len) return error.UnterminatedQuote;
        const val = open_inner[val_start..i];
        i += 1;

        if (std.mem.eql(u8, key, "summary")) {
            if (attrs.saw_summary) return error.DuplicateAttribute;
            attrs.saw_summary = true;
            if (!isValidDetailsSummary(val)) return error.InvalidSummary;
            attrs.summary = val;
        } else if (std.mem.eql(u8, key, "id")) {
            if (attrs.saw_id) return error.DuplicateAttribute;
            attrs.saw_id = true;
            if (!isValidAsideId(val)) return error.InvalidId;
            attrs.id = val;
        } else if (std.mem.eql(u8, key, "open")) {
            if (attrs.saw_open) return error.DuplicateAttribute;
            attrs.saw_open = true;
            if (!std.mem.eql(u8, val, "true")) return error.InvalidOpen;
            attrs.open = true;
        } else return error.UnknownAttribute;
    }
    if (!attrs.saw_summary) return error.InvalidSummary;
    return attrs;
}

fn appendAttributeDiagnostic(
    diagnostics: *std.ArrayList(Diagnostic),
    allocator: std.mem.Allocator,
    err: AttrError,
    line: u32,
    column: u32,
    name: []const u8,
) !void {
    const kind: DiagKind = switch (err) {
        error.DuplicateAttribute => .duplicate_attribute,
        error.UnknownAttribute => .unknown_attribute,
        error.UnterminatedQuote => .unterminated_quote,
        error.MalformedAttribute => .malformed_attribute,
        error.InvalidKind => .invalid_kind,
        error.InvalidId => .invalid_id,
        error.InvalidSummary => .invalid_summary,
        error.InvalidOpen => .invalid_open,
    };
    const message: []const u8 = switch (err) {
        error.DuplicateAttribute => "duplicate component attribute",
        error.UnknownAttribute => "unknown component attribute",
        error.UnterminatedQuote => "unterminated quote in component attribute",
        error.MalformedAttribute => "malformed component attribute (quoted values only)",
        error.InvalidKind => "invalid Aside kind (allowlist: note, tip, info, warning, danger)",
        error.InvalidId => "invalid component id (must match [A-Za-z0-9][A-Za-z0-9_-]* length 1..64)",
        error.InvalidSummary => "invalid Details summary (required plain text, length 1..256 bytes)",
        error.InvalidOpen => "invalid Details open attribute (only open=\"true\" is accepted)",
    };
    try diagnostics.append(allocator, .{ .kind = kind, .line = line, .column = column, .message = message, .name = name });
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const OpenState = struct {
    component: enum { aside, details },
    open_start: usize,
    open_end: usize, // index of '>'
    attrs: union(enum) { aside: ParsedAttrs, details: ParsedDetailsAttrs },
    line: u32,
    column: u32,
};

/// Tokenize a markdown body for Aside components.
///
/// Requires valid UTF-8 (`error.InvalidUtf8` otherwise). Allocates segment /
/// aside / diagnostic arrays from `allocator` (typically a document arena).
pub fn tokenizeBody(body: []const u8, allocator: std.mem.Allocator) !TokenizeResult {
    if (body.len > 0 and !std.unicode.utf8ValidateSlice(body)) {
        return error.InvalidUtf8;
    }

    var segments: std.ArrayList(Segment) = .empty;
    errdefer segments.deinit(allocator);
    var asides: std.ArrayList(Aside) = .empty;
    errdefer asides.deinit(allocator);
    var details: std.ArrayList(Details) = .empty;
    errdefer details.deinit(allocator);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer diagnostics.deinit(allocator);

    var md_start: usize = 0;
    var i: usize = 0;
    var fence_ch: u8 = 0;
    var fence_run: usize = 0;
    var open: ?OpenState = null;
    // Incremental line/column cursor — O(N) total instead of lineColAt rescans.
    var pos_index: usize = 0;
    var line: u32 = 1;
    var col: u32 = 1;
    const syncPos = struct {
        fn go(src: []const u8, index: usize, pi: *usize, ln: *u32, cl: *u32) void {
            if (index < pi.*) {
                pi.* = 0;
                ln.* = 1;
                cl.* = 1;
            }
            while (pi.* < index and pi.* < src.len) : (pi.* += 1) {
                if (src[pi.*] == '\n') {
                    ln.* += 1;
                    cl.* = 1;
                } else {
                    cl.* += 1;
                }
            }
        }
    }.go;

    while (i < body.len) {
        // Fence open/close only at line starts, and only when not mid-tag open wait.
        if (atLineStart(body, i)) {
            if (fenceAtLineStart(body, i)) |f| {
                const ch = f[0];
                const run = f[1];
                if (fence_ch == 0) {
                    // Opening fence — content stays markdown (literal).
                    fence_ch = ch;
                    fence_run = run;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                } else if (ch == fence_ch and run >= fence_run) {
                    // Closing fence.
                    fence_ch = 0;
                    fence_run = 0;
                    i = lineEndIndex(body, i);
                    if (i < body.len and body[i] == '\n') i += 1;
                    continue;
                }
            }
        }

        // Inside fenced code: never recognize components.
        if (fence_ch != 0) {
            i += 1;
            continue;
        }

        // Line-start close tag while a component is open.
        if (open != null and atLineStart(body, i)) {
            var j = i;
            while (j < body.len and isSpace(body[j])) : (j += 1) {}
            const close_name: ?[]const u8 = if (j + 8 <= body.len and std.mem.eql(u8, body[j .. j + 8], "</Aside>")) "Aside" else if (j + 10 <= body.len and std.mem.eql(u8, body[j .. j + 10], "</Details>")) "Details" else null;
            if (close_name) |name| {
                const after = j + name.len + 3;
                // Optional trailing whitespace to EOL.
                var k = after;
                while (k < body.len and (isSpace(body[k]) or body[k] == '\r')) : (k += 1) {}
                const at_eol = k >= body.len or body[k] == '\n';
                if (at_eol) {
                    const st = open.?;
                    const expected = if (st.component == .aside) "Aside" else "Details";
                    if (!std.mem.eql(u8, name, expected)) {
                        try diagnostics.append(allocator, .{ .kind = .nested_component, .line = line, .column = col, .message = "cross-nested component close tag is not supported", .name = name });
                        i = k;
                        continue;
                    }
                    // Flush markdown before open tag.
                    if (st.open_start > md_start) {
                        try segments.append(allocator, .{ .markdown = body[md_start..st.open_start] });
                    }
                    const inner_body = body[st.open_end + 1 .. i];
                    switch (st.attrs) {
                        .aside => |attrs| {
                            const a: Aside = .{ .kind = attrs.kind, .id = attrs.id, .body = inner_body, .raw_span = body[st.open_start..k], .line = st.line, .column = st.column };
                            try asides.append(allocator, a);
                            try segments.append(allocator, .{ .aside = a });
                        },
                        .details => |attrs| {
                            const d: Details = .{ .summary = attrs.summary, .id = attrs.id, .open = attrs.open, .body = inner_body, .raw_span = body[st.open_start..k], .line = st.line, .column = st.column };
                            try details.append(allocator, d);
                            try segments.append(allocator, .{ .details = d });
                        },
                    }
                    open = null;
                    // Skip close line including newline.
                    i = if (k < body.len and body[k] == '\n') k + 1 else k;
                    md_start = i;
                    continue;
                }
            }
        }

        // Potential open tag: '<' + PascalCase name.
        if (body[i] == '<' and i + 1 < body.len and body[i + 1] >= 'A' and body[i + 1] <= 'Z') {
            const name_start = i + 1;
            var name_end = name_start;
            while (name_end < body.len) {
                const c = body[name_end];
                const ok = (c >= 'A' and c <= 'Z') or
                    (c >= 'a' and c <= 'z') or
                    (c >= '0' and c <= '9') or
                    c == '_' or c == '-';
                if (!ok) break;
                name_end += 1;
            }
            const name = body[name_start..name_end];
            if (isPascalComponentName(name) and tagNameBoundaryOk(body, name_end)) {
                syncPos(body, i, &pos_index, &line, &col);

                // Find closing '>'. Attributes are single-line: a newline resets
                // quote mode so an unmatched `"` cannot suppress `<` early-exit
                // for the rest of the file (O(N²) rescans on malformed tags).
                var gt = name_end;
                var in_quote = false;
                while (gt < body.len) : (gt += 1) {
                    const c = body[gt];
                    if (c == '\n' or c == '\r') {
                        in_quote = false;
                        break; // unclosed tag before EOL
                    }
                    if (c == '"') in_quote = !in_quote;
                    if (!in_quote and c == '>') break;
                    if (!in_quote and c == '<') break; // nested open / garbage
                }
                if (gt >= body.len or body[gt] != '>') {
                    try diagnostics.append(allocator, .{
                        .kind = .missing_close_angle,
                        .line = line,
                        .column = col,
                        .message = "component open tag is missing closing '>'",
                        .name = name,
                    });
                    // Skip the '<' so we make progress (line-bounded scan above).
                    i += 1;
                    continue;
                }

                if (!std.mem.eql(u8, name, "Aside") and !std.mem.eql(u8, name, "Details")) {
                    try diagnostics.append(allocator, .{
                        .kind = .unregistered_component,
                        .line = line,
                        .column = col,
                        .message = "unregistered component tag",
                        .name = name,
                    });
                    i = gt + 1;
                    continue;
                }

                // Components cannot nest or cross-nest.
                if (open != null) {
                    try diagnostics.append(allocator, .{
                        .kind = .nested_component,
                        .line = line,
                        .column = col,
                        .message = "nested or cross-nested component is not supported",
                        .name = name,
                    });
                    i = gt + 1;
                    continue;
                }

                const attr_slice = body[name_end..gt];
                if (std.mem.eql(u8, name, "Aside")) {
                    const attrs = parseAttributes(attr_slice) catch |err| {
                        try appendAttributeDiagnostic(&diagnostics, allocator, err, line, col, "Aside");
                        i = gt + 1;
                        continue;
                    };
                    open = .{ .component = .aside, .open_start = i, .open_end = gt, .attrs = .{ .aside = attrs }, .line = line, .column = col };
                } else {
                    const attrs = parseDetailsAttributes(attr_slice) catch |err| {
                        try appendAttributeDiagnostic(&diagnostics, allocator, err, line, col, "Details");
                        i = gt + 1;
                        continue;
                    };
                    open = .{ .component = .details, .open_start = i, .open_end = gt, .attrs = .{ .details = attrs }, .line = line, .column = col };
                }
                i = gt + 1;
                continue;
            }
        }

        i += 1;
    }

    if (open) |st| {
        try diagnostics.append(allocator, .{
            .kind = .unterminated_component,
            .line = st.line,
            .column = st.column,
            .message = if (st.component == .aside) "unterminated Aside (missing line-start </Aside>)" else "unterminated Details (missing line-start </Details>)",
            .name = if (st.component == .aside) "Aside" else "Details",
        });
        // Do not emit a partial aside segment; leave open-span as markdown.
    }

    if (md_start < body.len) {
        try segments.append(allocator, .{ .markdown = body[md_start..] });
    } else if (segments.items.len == 0 and body.len == 0) {
        // empty body → empty markdown segment for uniform consumers
        try segments.append(allocator, .{ .markdown = body });
    }

    return .{
        .segments = try segments.toOwnedSlice(allocator),
        .asides = try asides.toOwnedSlice(allocator),
        .details = try details.toOwnedSlice(allocator),
        .diagnostics = try diagnostics.toOwnedSlice(allocator),
    };
}

/// Alias used by harness / fuzz.
pub fn parseBodySegmentsSimple(body: []const u8, allocator: std.mem.Allocator) !TokenizeResult {
    return tokenizeBody(body, allocator);
}

// ---------------------------------------------------------------------------
// HTML render
// ---------------------------------------------------------------------------

/// CSS class stem from kind (sanitized to [a-z0-9_-]).
fn sanitizeClass(comptime max: usize, raw: []const u8, buf: *[max]u8) []const u8 {
    var n: usize = 0;
    for (raw) |c| {
        if (n >= max) break;
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_';
        if (ok) {
            buf[n] = if (c >= 'A' and c <= 'Z') c + 32 else c;
            n += 1;
        }
    }
    if (n == 0) {
        const fallback = "note";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    return buf[0..n];
}

fn appendEscapedAttr(out: *std.ArrayList(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '"' => try out.appendSlice(gpa, "&quot;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, c),
        }
    }
}

/// Title-case-ish label for aria-label (first letter upper if ascii alpha).
fn kindLabel(kind: []const u8, buf: *[64]u8) []const u8 {
    if (kind.len == 0) {
        const fallback = "Note";
        @memcpy(buf[0..fallback.len], fallback);
        return buf[0..fallback.len];
    }
    const n = @min(kind.len, buf.len);
    @memcpy(buf[0..n], kind[0..n]);
    if (n > 0 and buf[0] >= 'a' and buf[0] <= 'z') {
        buf[0] = buf[0] - 32;
    }
    return buf[0..n];
}

/// Render one Aside to an HTML admonition. Allocates from the document Whiteboard.
pub fn renderHtml(a: Aside, doc_arena: *std.heap.ArenaAllocator) ![]const u8 {
    const arena = doc_arena.allocator();
    var class_buf: [64]u8 = undefined;
    const kind = sanitizeClass(64, a.kind, &class_buf);
    var label_buf: [64]u8 = undefined;
    const label = kindLabel(kind, &label_buf);

    const inner = if (a.body.len > 0)
        (try apex.render(a.body, doc_arena)).bytes
    else
        "";

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "<aside class=\"admonition admonition--");
    try out.appendSlice(arena, kind);
    try out.appendSlice(arena, "\"");
    if (a.id.len > 0) {
        try out.appendSlice(arena, " id=\"");
        try appendEscapedAttr(&out, arena, a.id);
        try out.appendSlice(arena, "\"");
    }
    try out.appendSlice(arena, " aria-label=\"");
    try appendEscapedAttr(&out, arena, label);
    try out.appendSlice(arena, "\">\n");
    try out.appendSlice(arena, "<p class=\"admonition__title\">");
    try out.appendSlice(arena, label);
    try out.appendSlice(arena, "</p>\n");
    try out.appendSlice(arena, "<div class=\"admonition__body\">\n");
    try out.appendSlice(arena, inner);
    try out.appendSlice(arena, "</div>\n</aside>\n");

    return try out.toOwnedSlice(arena);
}

/// Render one Details component using the platform-native disclosure elements.
/// The summary is intentionally emitted as escaped text, never Markdown.
pub fn renderDetailsHtml(d: Details, doc_arena: *std.heap.ArenaAllocator) ![]const u8 {
    const arena = doc_arena.allocator();
    const inner = if (d.body.len > 0) (try apex.render(d.body, doc_arena)).bytes else "";
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "<details class=\"details\"");
    if (d.id.len > 0) {
        try out.appendSlice(arena, " id=\"");
        try appendEscapedAttr(&out, arena, d.id);
        try out.appendSlice(arena, "\"");
    }
    if (d.open) try out.appendSlice(arena, " open");
    try out.appendSlice(arena, ">\n<summary>");
    try appendEscapedAttr(&out, arena, d.summary);
    try out.appendSlice(arena, "</summary>\n<div class=\"details__body\">\n");
    try out.appendSlice(arena, inner);
    try out.appendSlice(arena, "</div>\n</details>\n");
    return try out.toOwnedSlice(arena);
}

// ---------------------------------------------------------------------------
// RAG export representation (non-round-trippable)
// ---------------------------------------------------------------------------

/// Format one Aside as an export-only `:::kind` block.
///
/// Kind and id are already allowlist/grammar-validated at tokenize time.
/// Body is written verbatim (export representation for retrieval, not HTML).
pub fn formatRagDirective(a: Aside, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, ":::");
    try out.appendSlice(allocator, a.kind);
    if (a.id.len > 0) {
        try out.appendSlice(allocator, "{id=\"");
        try out.appendSlice(allocator, a.id);
        try out.appendSlice(allocator, "\"}");
    }
    try out.append(allocator, '\n');
    // Trim a single leading newline from inner body for cleaner export.
    var body = a.body;
    if (body.len > 0 and body[0] == '\n') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
    try out.appendSlice(allocator, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, ":::\n");
    return try out.toOwnedSlice(allocator);
}

/// Format Details as an inline, export-only RAG directive. The body remains
/// source Markdown; the summary is escaped for the directive attribute sink.
pub fn formatDetailsRagDirective(d: Details, allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, ":::details{summary=\"");
    try appendEscapedAttr(&out, allocator, d.summary);
    try out.appendSlice(allocator, "\"");
    if (d.id.len > 0) {
        try out.appendSlice(allocator, " id=\"");
        try appendEscapedAttr(&out, allocator, d.id);
        try out.appendSlice(allocator, "\"");
    }
    if (d.open) try out.appendSlice(allocator, " open=\"true\"");
    try out.appendSlice(allocator, "}\n");
    var body = d.body;
    if (body.len > 0 and body[0] == '\n') body = body[1..];
    if (body.len > 0 and body[body.len - 1] == '\r') body = body[0 .. body.len - 1];
    try out.appendSlice(allocator, body);
    if (body.len == 0 or body[body.len - 1] != '\n') try out.append(allocator, '\n');
    try out.appendSlice(allocator, ":::\n");
    return try out.toOwnedSlice(allocator);
}

/// Rebuild a body for RAG: markdown segments H1-normalized by caller pieces,
/// asides as `:::kind` blocks, document order preserved.
pub fn exportBodyWithDirectives(
    segments: []const Segment,
    prepare_md: *const fn ([]const u8, std.mem.Allocator) anyerror![]const u8,
    allocator: std.mem.Allocator,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) {
                    try out.appendSlice(allocator, md);
                    continue;
                }
                const prepared = try prepare_md(md, allocator);
                try out.appendSlice(allocator, prepared);
            },
            .aside => |a| {
                const block = try formatRagDirective(a, allocator);
                defer allocator.free(block);
                try out.appendSlice(allocator, block);
            },
            .details => |d| {
                const block = try formatDetailsRagDirective(d, allocator);
                defer allocator.free(block);
                try out.appendSlice(allocator, block);
            },
        }
    }
    return try out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Diagnostic → pipeline code mapping
// ---------------------------------------------------------------------------

pub fn diagnosticMessage(d: Diagnostic) []const u8 {
    return d.message;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "renderHtml wraps tip" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try renderHtml(.{
        .kind = "tip",
        .id = "006-1",
        .body = "Stay **hydrated**.",
        .raw_span = "",
    }, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "class=\"admonition admonition--tip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"006-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "aria-label=\"Tip\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>hydrated</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<Aside") == null);
}

test "renderHtml omits id when empty" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try renderHtml(.{
        .kind = "warning",
        .id = "",
        .body = "Careful.",
        .raw_span = "",
    }, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "admonition--warning") != null);
}

test "renderHtml escapes id attribute sinks" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Bypass parse grammar: defensive escape still applies if id were hostile.
    const html = try renderHtml(.{
        .kind = "note",
        .id = "a\"b&c",
        .body = "x",
        .raw_span = "",
    }, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"a&quot;b&amp;c\"") != null);
}

test "renderDetailsHtml uses native semantics and escapes text sinks" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try renderDetailsHtml(.{
        .summary = "A < B & \"quoted\"",
        .id = "detail-1",
        .open = true,
        .body = "Inside **body**.",
    }, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "<details class=\"details\" id=\"detail-1\" open>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<summary>A &lt; B &amp; &quot;quoted&quot;</summary>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<div class=\"details__body\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>body</strong>") != null);
}

test "tokenize: valid Details attributes and RAG projection" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try tokenizeBody(
        \\<Details summary="Read <this> & that" id="more-1" open="true">
        \\Inside.
        \\</Details>
    , arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.details.len);
    try std.testing.expect(r.details[0].open);
    const rag = try formatDetailsRagDirective(r.details[0], gpa);
    defer gpa.free(rag);
    try std.testing.expect(std.mem.indexOf(u8, rag, ":::details{summary=\"Read &lt;this&gt; &amp; that\" id=\"more-1\" open=\"true\"}") != null);
}

test "tokenize: Details rejects closed grammar and cross nesting" {
    const gpa = std.testing.allocator;
    var too_long: [max_details_summary_bytes + 1]u8 = undefined;
    @memset(&too_long, 'x');
    try std.testing.expect(!isValidDetailsSummary(""));
    try std.testing.expect(!isValidDetailsSummary(&too_long));
    const cases = [_]struct { body: []const u8, kind: DiagKind }{
        .{ .body = "<Details>\nx\n</Details>\n", .kind = .invalid_summary },
        .{ .body = "<Details summary=\"x\" open=\"false\">\nx\n</Details>\n", .kind = .invalid_open },
        .{ .body = "<Details summary=\"x\" class=\"no\">\nx\n</Details>\n", .kind = .unknown_attribute },
        .{ .body = "<Details summary=\"x\" summary=\"y\">\nx\n</Details>\n", .kind = .duplicate_attribute },
        .{ .body = "<Details summary=\"x\"\n", .kind = .missing_close_angle },
        .{ .body = "<Details summary=\"x\">\n<Aside kind=\"tip\">\ny\n</Details>\n</Aside>\n", .kind = .nested_component },
        .{ .body = "<Aside kind=\"tip\">\nx\n</Details>\n", .kind = .nested_component },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const r = try tokenizeBody(case.body, arena.allocator());
        try std.testing.expect(r.hasErrors());
        var found = false;
        for (r.diagnostics) |d| {
            if (d.kind == case.kind) found = true;
        }
        try std.testing.expect(found);
    }
}

test "tokenize: fenced Details remains literal" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try tokenizeBody("```md\n<Details summary=\"literal\">\nx\n</Details>\n```\n", arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.details.len);
}

test "tokenize: valid Aside with optional id" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\Hello **world**.
        \\
        \\<Aside kind="warning" id="w1">
        \\Careful.
        \\</Aside>
        \\
        \\Done.
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expectEqualStrings("warning", r.asides[0].kind);
    try std.testing.expectEqualStrings("w1", r.asides[0].id);
    try std.testing.expect(std.mem.indexOf(u8, r.asides[0].body, "Careful") != null);
    try std.testing.expectEqual(@as(usize, 3), r.segments.len);
}

test "tokenize: invalid kind" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Aside kind="banana">
        \\x
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .invalid_kind);
}

test "tokenize: duplicate attribute" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Aside kind="tip" kind="note">
        \\x
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .duplicate_attribute);
}

test "tokenize: unterminated quote" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Aside kind="tip>
        \\x
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    var saw = false;
    for (r.diagnostics) |d| {
        if (d.kind == .unterminated_quote or d.kind == .missing_close_angle or d.kind == .malformed_attribute)
            saw = true;
    }
    try std.testing.expect(saw);
}

test "tokenize: nested Aside" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Aside kind="tip">
        \\outer
        \\<Aside kind="note">
        \\inner
        \\</Aside>
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    var saw_nested = false;
    for (r.diagnostics) |d| {
        if (d.kind == .nested_component) saw_nested = true;
    }
    try std.testing.expect(saw_nested);
}

test "tokenize: unknown component tag" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body = "<Figure src=\"x\">y</Figure>\n";
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .unregistered_component);
    try std.testing.expectEqualStrings("Figure", r.diagnostics[0].name);
}

test "tokenize: Broside is unregistered" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Broside kind="tip">
        \\no
        \\</Broside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .unregistered_component);
}

test "tokenize: fenced code keeps Aside literal" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\Before
        \\
        \\```md
        \\<Aside kind="tip">
        \\example
        \\</Aside>
        \\```
        \\
        \\After
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 0), r.asides.len);
    // Whole body is one markdown segment (or multiple md with no asides).
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (r.segments) |seg| {
        switch (seg) {
            .markdown => |md| try joined.appendSlice(gpa, md),
            .aside => try std.testing.expect(false),
            .details => try std.testing.expect(false),
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "<Aside kind=\"tip\">") != null);
}

test "tokenize: real Aside after fence still works" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\```
        \\<Aside kind="tip">
        \\literal
        \\</Aside>
        \\```
        \\
        \\<Aside kind="note" id="n1">
        \\real
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(!r.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), r.asides.len);
    try std.testing.expectEqualStrings("note", r.asides[0].kind);
    try std.testing.expectEqualStrings("n1", r.asides[0].id);
}

test "tokenize: unterminated Aside" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const r = try tokenizeBody("<Aside kind=\"tip\">\nno close\n", arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .unterminated_component);
}

test "tokenize: invalid id grammar" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\<Aside kind="tip" id="bad!">
        \\x
        \\</Aside>
        \\
    ;
    const r = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(r.hasErrors());
    try std.testing.expect(r.diagnostics[0].kind == .invalid_id);
}

test "formatRagDirective export representation" {
    const gpa = std.testing.allocator;
    const block = try formatRagDirective(.{
        .kind = "tip",
        .id = "z1",
        .body = "Tip body.\n",
    }, gpa);
    defer gpa.free(block);
    try std.testing.expectEqualStrings(":::tip{id=\"z1\"}\nTip body.\n:::\n", block);
}

test "isValidAsideId grammar" {
    try std.testing.expect(isValidAsideId("a"));
    try std.testing.expect(isValidAsideId("006-1"));
    try std.testing.expect(isValidAsideId("ok_1"));
    try std.testing.expect(!isValidAsideId(""));
    try std.testing.expect(!isValidAsideId("bad!"));
    try std.testing.expect(!isValidAsideId("-lead"));
    try std.testing.expect(!isValidAsideId("has space"));
}

test "tokenize rejects invalid UTF-8" {
    const gpa = std.testing.allocator;
    const bad = [_]u8{ 0xFF, 0xFE, '<', 'A', 's', 'i', 'd', 'e', '>' };
    try std.testing.expectError(error.InvalidUtf8, tokenizeBody(&bad, gpa));
}

// U15: Zig Aside stream stays in document order under real Apex Unified.
// Mirrors compile's segment walk: markdown → apex.render, aside → renderHtml.
test "U15 Aside document order with real Apex stream" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\AAA_MARKER
        \\
        \\<Aside kind="note" id="n1">
        \\INNER **bold** and a table:
        \\
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\</Aside>
        \\
        \\BBB_MARKER
        \\
    ;
    const tok = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(tok.diagnostics.len == 0);
    try std.testing.expect(tok.segments.len >= 3);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (tok.segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try apex.render(md, &arena);
                try out.appendSlice(gpa, h.bytes);
            },
            .aside => |a| {
                const h = try renderHtml(a, &arena);
                try out.appendSlice(gpa, h);
            },
            .details => |d| {
                const h = try renderDetailsHtml(d, &arena);
                try out.appendSlice(gpa, h);
            },
        }
    }
    const html = out.items;
    const i_aaa = std.mem.indexOf(u8, html, "AAA_MARKER") orelse return error.TestUnexpectedResult;
    const i_aside = std.mem.indexOf(u8, html, "admonition--note") orelse return error.TestUnexpectedResult;
    const i_bbb = std.mem.indexOf(u8, html, "BBB_MARKER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_aaa < i_aside);
    try std.testing.expect(i_aside < i_bbb);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"n1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<strong>bold</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<table") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<Aside") == null);
}

// Aside body is re-rendered via apex.render — Unified callouts must survive
// (not double-escaped or dropped). Complements U15 table-in-Aside coverage.
test "U15b Apex callout inside Aside body renders through" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const body =
        \\BEFORE
        \\
        \\<Aside kind="tip" id="t-call">
        \\> [!NOTE]
        \\> CALL-IN-ASIDE body
        \\</Aside>
        \\
        \\AFTER
        \\
    ;
    const tok = try tokenizeBody(body, arena.allocator());
    try std.testing.expect(tok.diagnostics.len == 0);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (tok.segments) |seg| {
        switch (seg) {
            .markdown => |md| {
                if (std.mem.trim(u8, md, " \t\r\n").len == 0) continue;
                const h = try apex.render(md, &arena);
                try out.appendSlice(gpa, h.bytes);
            },
            .aside => |a| {
                const h = try renderHtml(a, &arena);
                try out.appendSlice(gpa, h);
            },
            .details => |d| {
                const h = try renderDetailsHtml(d, &arena);
                try out.appendSlice(gpa, h);
            },
        }
    }
    const html = out.items;
    const i_before = std.mem.indexOf(u8, html, "BEFORE") orelse return error.TestUnexpectedResult;
    const i_tip = std.mem.indexOf(u8, html, "admonition--tip") orelse return error.TestUnexpectedResult;
    const i_call = std.mem.indexOf(u8, html, "callout") orelse return error.TestUnexpectedResult;
    const i_body = std.mem.indexOf(u8, html, "CALL-IN-ASIDE") orelse return error.TestUnexpectedResult;
    const i_after = std.mem.indexOf(u8, html, "AFTER") orelse return error.TestUnexpectedResult;
    try std.testing.expect(i_before < i_tip);
    try std.testing.expect(i_tip < i_call);
    try std.testing.expect(i_call < i_body or i_tip < i_body);
    try std.testing.expect(i_body < i_after);
    try std.testing.expect(std.mem.indexOf(u8, html, "id=\"t-call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<Aside") == null);
}
