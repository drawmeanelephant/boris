//! Feature 6 follow-on — in-page heading `{{toc}}`.
//!
//! Builds a per-page outline from **rendered body HTML** (Apex + Aside), so
//! `href="#id"` targets match the `id` attributes Apex already emitted.
//! Does not re-implement Apex slug rules in Markdown.

const std = @import("std");
const html_nav = @import("html_nav.zig");

/// Inclusive heading levels included in `{{toc}}` (h1–h3).
pub const toc_min_level: u8 = 1;
pub const toc_max_level: u8 = 3;

/// Inclusive levels harvested for wiki fragment targets (h1–h6).
pub const fragment_min_level: u8 = 1;
pub const fragment_max_level: u8 = 6;

pub const Heading = struct {
    level: u8,
    id: []const u8,
    /// Inner text with tags stripped; HTML entities left as Apex emitted them.
    text: []const u8,
};

fn closePattern(level: u8) []const u8 {
    return switch (level) {
        1 => "</h1>",
        2 => "</h2>",
        3 => "</h3>",
        4 => "</h4>",
        5 => "</h5>",
        6 => "</h6>",
        else => unreachable,
    };
}

/// Collect headings in `[min_level, max_level]` that have an `id` attribute.
/// Slices for `id` point into `html`; `text` is allocator-owned.
pub fn collectHeadingsInRange(
    allocator: std.mem.Allocator,
    html: []const u8,
    min_level: u8,
    max_level: u8,
    out: *std.ArrayList(Heading),
) !void {
    var i: usize = 0;
    while (i < html.len) {
        const open = std.mem.indexOfPos(u8, html, i, "<h") orelse break;
        if (open + 3 > html.len) break;
        const level_ch = html[open + 2];
        if (level_ch < '1' or level_ch > '6') {
            i = open + 2;
            continue;
        }
        const level: u8 = level_ch - '0';
        // Require tag boundary: <hN or <hN> or <hN …
        if (open + 3 < html.len) {
            const next = html[open + 3];
            if (next != '>' and next != ' ' and next != '\t' and next != '\n' and next != '\r') {
                i = open + 2;
                continue;
            }
        }
        if (level < min_level or level > max_level) {
            // Skip to after this heading to avoid nested false matches.
            if (std.mem.indexOfPos(u8, html, open, "</h")) |close_h| {
                i = close_h + 1;
            } else {
                i = open + 3;
            }
            continue;
        }

        const gt = findTagEnd(html, open) orelse break;
        const open_tag = html[open .. gt + 1];
        const id = extractIdAttr(open_tag) orelse {
            i = gt + 1;
            continue;
        };

        const close_pat = closePattern(level);
        const close = std.mem.indexOfPos(u8, html, gt + 1, close_pat) orelse {
            i = gt + 1;
            continue;
        };
        const inner = html[gt + 1 .. close];
        const text = try stripTags(allocator, inner);
        // Free on append OOM only — after a successful append, list owns `text`.
        out.append(allocator, .{
            .level = level,
            .id = id,
            .text = text,
        }) catch |err| {
            allocator.free(text);
            return err;
        };
        i = close + close_pat.len;
    }
}

/// Collect h1–h3 headings that have an `id` attribute, document order.
/// Slices point into `html` (or into `scratch` for stripped text when tags appear).
pub fn collectHeadings(
    allocator: std.mem.Allocator,
    html: []const u8,
    out: *std.ArrayList(Heading),
) !void {
    return collectHeadingsInRange(allocator, html, toc_min_level, toc_max_level, out);
}

/// Collect unique non-empty heading `id` attributes for h1–h6 (wiki fragment set).
/// Each returned id is allocator-owned; free with `allocator.free` per entry.
pub fn collectHeadingIds(
    allocator: std.mem.Allocator,
    html: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    var headings: std.ArrayList(Heading) = .empty;
    defer {
        for (headings.items) |h| allocator.free(h.text);
        headings.deinit(allocator);
    }
    try collectHeadingsInRange(allocator, html, fragment_min_level, fragment_max_level, &headings);

    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    for (headings.items) |h| {
        if (h.id.len == 0) continue;
        const gop = try seen.getOrPut(allocator, h.id);
        if (gop.found_existing) continue;
        // Own a copy: `h.id` views into `html`, which may outlive the caller’s buffer.
        const owned = try allocator.dupe(u8, h.id);
        errdefer allocator.free(owned);
        // Re-key seen with owned pointer so the map does not point at `html`.
        gop.key_ptr.* = owned;
        try out.append(allocator, owned);
    }
}

/// Find the closing `>` of an HTML tag, ignoring `>` bytes inside quoted
/// attribute values. `start` must point at the tag's `<`.
fn findTagEnd(html: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var i = start + 1;
    while (i < html.len) : (i += 1) {
        const ch = html[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        if (ch == '\"' or ch == '\'') {
            quote = ch;
        } else if (ch == '>') {
            return i;
        }
    }
    return null;
}

fn extractIdAttr(open_tag: []const u8) ?[]const u8 {
    // Skip `<hN`, then parse exact attribute names and quoted/unquoted values.
    // This avoids mistaking `data-id` or `id="..."` text inside another
    // attribute value for the heading id.
    if (open_tag.len < 4) return null;
    var i: usize = 3;
    while (i < open_tag.len) {
        while (i < open_tag.len and std.ascii.isWhitespace(open_tag[i])) : (i += 1) {}
        if (i >= open_tag.len or open_tag[i] == '>') break;

        const name_start = i;
        while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and
            open_tag[i] != '=' and open_tag[i] != '>') : (i += 1)
        {}
        if (i == name_start) {
            i += 1;
            continue;
        }
        const name = open_tag[name_start..i];
        while (i < open_tag.len and std.ascii.isWhitespace(open_tag[i])) : (i += 1) {}
        if (i >= open_tag.len or open_tag[i] != '=') continue;
        i += 1;
        while (i < open_tag.len and std.ascii.isWhitespace(open_tag[i])) : (i += 1) {}
        if (i >= open_tag.len) return null;

        const value: []const u8 = value: {
            if (open_tag[i] == '\"' or open_tag[i] == '\'') {
                const quote = open_tag[i];
                i += 1;
                const start = i;
                while (i < open_tag.len and open_tag[i] != quote) : (i += 1) {}
                if (i >= open_tag.len) return null;
                const parsed = open_tag[start..i];
                i += 1;
                break :value parsed;
            }
            const start = i;
            while (i < open_tag.len and !std.ascii.isWhitespace(open_tag[i]) and open_tag[i] != '>') : (i += 1) {}
            break :value open_tag[start..i];
        };
        if (std.ascii.eqlIgnoreCase(name, "id")) return if (value.len > 0) value else null;
    }
    return null;
}

/// Strip HTML tags from heading inner HTML. Entities (e.g. `&amp;`) are kept.
fn stripTags(allocator: std.mem.Allocator, inner: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, inner, '<') == null) {
        return try allocator.dupe(u8, std.mem.trim(u8, inner, " \t\r\n"));
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '<') {
            const end = findTagEnd(inner, i) orelse {
                // Unclosed tag: drop rest.
                break;
            };
            i = end + 1;
            continue;
        }
        try buf.append(allocator, inner[i]);
        i += 1;
    }
    const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

/// Render `{{toc}}` HTML from body HTML. Empty string when no h1–h3 with ids.
pub fn renderToc(allocator: std.mem.Allocator, body_html: []const u8) ![]u8 {
    var headings: std.ArrayList(Heading) = .empty;
    defer {
        for (headings.items) |h| allocator.free(h.text);
        headings.deinit(allocator);
    }
    try collectHeadings(allocator, body_html, &headings);
    if (headings.items.len == 0) return try allocator.dupe(u8, "");

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<nav class=\"page-toc\" aria-label=\"On this page\">\n<ul>\n");
    for (headings.items) |h| {
        try buf.appendSlice(allocator, "<li class=\"page-toc__l");
        try buf.append(allocator, '0' + h.level);
        try buf.appendSlice(allocator, "\"><a href=\"#");
        // ids are usually slug-safe; still escape attribute specials
        try html_nav.appendEscaped(&buf, allocator, h.id);
        try buf.appendSlice(allocator, "\">");
        // Text already entity-escaped from Apex; do not double-escape.
        try buf.appendSlice(allocator, h.text);
        try buf.appendSlice(allocator, "</a></li>\n");
    }
    try buf.appendSlice(allocator, "</ul>\n</nav>");
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "collectHeadings h1-h3 with ids; skip h4" {
    const gpa = std.testing.allocator;
    const html =
        \\<h1 id="hello-world">Hello World</h1>
        \\<h2 id="sub-more">Sub &amp; More</h2>
        \\<h3 id="deep">Deep</h3>
        \\<h2 id="hello-world">Hello World</h2>
        \\<h4 id="too-deep">Too deep</h4>
    ;
    var list: std.ArrayList(Heading) = .empty;
    defer {
        for (list.items) |h| gpa.free(h.text);
        list.deinit(gpa);
    }
    try collectHeadings(gpa, html, &list);
    try std.testing.expectEqual(@as(usize, 4), list.items.len);
    try std.testing.expectEqual(@as(u8, 1), list.items[0].level);
    try std.testing.expectEqualStrings("hello-world", list.items[0].id);
    try std.testing.expectEqualStrings("Hello World", list.items[0].text);
    try std.testing.expectEqualStrings("sub-more", list.items[1].id);
    try std.testing.expectEqualStrings("Sub &amp; More", list.items[1].text);
    try std.testing.expectEqual(@as(u8, 3), list.items[2].level);
    try std.testing.expectEqualStrings("deep", list.items[2].id);
}

test "collectHeadings ignores > inside attribute values" {
    const gpa = std.testing.allocator;
    const html =
        \\<h2 id="x" title="a>b">Real</h2>
        \\<h2 title="a>b" id="y">Also Real</h2>
    ;
    var list: std.ArrayList(Heading) = .empty;
    defer {
        for (list.items) |h| gpa.free(h.text);
        list.deinit(gpa);
    }
    try collectHeadings(gpa, html, &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("x", list.items[0].id);
    try std.testing.expectEqualStrings("Real", list.items[0].text);
    try std.testing.expectEqualStrings("y", list.items[1].id);
    try std.testing.expectEqualStrings("Also Real", list.items[1].text);
}

test "renderToc empty when no headings" {
    const gpa = std.testing.allocator;
    const toc = try renderToc(gpa, "<p>no headings</p>");
    defer gpa.free(toc);
    try std.testing.expectEqualStrings("", toc);
}

test "renderToc shape and anchors" {
    const gpa = std.testing.allocator;
    const html =
        \\<h1 id="top">Top</h1>
        \\<h2 id="sec">Section <em>X</em></h2>
    ;
    const toc = try renderToc(gpa, html);
    defer gpa.free(toc);
    try std.testing.expect(std.mem.indexOf(u8, toc, "page-toc") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "aria-label=\"On this page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "href=\"#top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "href=\"#sec\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "page-toc__l1") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "page-toc__l2") != null);
    // Em tags stripped; no double-escape.
    try std.testing.expect(std.mem.indexOf(u8, toc, "Section X") != null);
}

test "renderToc emits a labeled list landmark and preserves rendered text entities" {
    const gpa = std.testing.allocator;
    const toc = try renderToc(gpa, "<h2 id=\"a&amp;b&lt;c&gt;\">A &amp; <em>B</em></h2>");
    defer gpa.free(toc);
    try std.testing.expectEqualStrings(
        "<nav class=\"page-toc\" aria-label=\"On this page\">\n" ++
            "<ul>\n" ++
            "<li class=\"page-toc__l2\"><a href=\"#a&amp;amp;b&amp;lt;c&amp;gt;\">A &amp; B</a></li>\n" ++
            "</ul>\n" ++
            "</nav>",
        toc,
    );
}

test "renderToc skips headings without id" {
    const gpa = std.testing.allocator;
    const toc = try renderToc(gpa, "<h2>No id</h2><h2 id=\"has\">Has</h2>");
    defer gpa.free(toc);
    try std.testing.expect(std.mem.indexOf(u8, toc, "href=\"#has\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "No id") == null);
}

test "collectHeadings ignores greater-than inside quoted heading attributes" {
    const gpa = std.testing.allocator;
    const html = "<h2 title=\"1 > 0 and id='fake'\" data-id=\"also-fake\" id = 'real'>Real <em title=\"x > y\">Title</em></h2>";
    var list: std.ArrayList(Heading) = .empty;
    defer {
        for (list.items) |h| gpa.free(h.text);
        list.deinit(gpa);
    }
    try collectHeadings(gpa, html, &list);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("real", list.items[0].id);
    try std.testing.expectEqualStrings("Real Title", list.items[0].text);
}

fn collectHeadingsAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var list: std.ArrayList(Heading) = .empty;
    defer {
        for (list.items) |h| allocator.free(h.text);
        list.deinit(allocator);
    }
    try collectHeadings(allocator, "<h2 id=\"one\">One <em>heading</em></h2>", &list);
}

test "collectHeadings frees stripped text when append allocation fails" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        collectHeadingsAllocationFailureCase,
        .{},
    );
}

test "collectHeadingIds h1-h6 unique set includes h4" {
    const gpa = std.testing.allocator;
    const html =
        \\<h1 id="top">Top</h1>
        \\<h2 id="sec">Sec</h2>
        \\<h2 id="sec">Dup sec</h2>
        \\<h4 id="deep">Deep</h4>
    ;
    var ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (ids.items) |id| gpa.free(id);
        ids.deinit(gpa);
    }
    try collectHeadingIds(gpa, html, &ids);
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    try std.testing.expectEqualStrings("top", ids.items[0]);
    try std.testing.expectEqualStrings("sec", ids.items[1]);
    try std.testing.expectEqualStrings("deep", ids.items[2]);
}
