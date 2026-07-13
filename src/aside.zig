//! Aside / admonition HTML rendering — built-in documentation callouts.
//!
//! Asides are in-document components. They stay in page order and render as
//! semantic `<aside class="admonition admonition--{kind}">`. They do **not**
//! become standalone fragment pages or graph nodes.
//!
//! Inner body goes through Apex (markdown → HTML) just like main prose.

const std = @import("std");
const apex = @import("apex.zig");

/// Structured callout extracted from `<Aside kind="…" id="…">…</Aside>`.
/// All string fields are slices into the parent page's raw source (zero-copy).
///
/// Canonical name is **Aside** (not a mascot brand). Nested asides are
/// unsupported (hard error in `parser.zig`). `id` is parse-validated to a
/// safe identifier grammar; HTML still escapes attribute sinks defensively.
pub const Aside = struct {
    /// Semantic kind: note, tip, info, warning, danger, … (from kind= or legacy type=).
    kind: []const u8 = "",
    /// Optional stable in-page anchor (empty when omitted).
    id: []const u8 = "",
    /// Inner markdown between open and close tags (slice into source).
    body: []const u8 = "",
    /// Full span of the original tag in source, for diagnostics.
    raw_span: []const u8 = "",
    /// 1-based line of the opening tag in the full source file.
    line: u32 = 1,
    /// 1-based byte column of the opening tag.
    column: u32 = 1,
};

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

    // Inner markdown → HTML via native Apex (same whiteboard path as page body).
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
