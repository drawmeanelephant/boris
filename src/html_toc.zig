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

pub const Heading = struct {
    level: u8,
    id: []const u8,
    /// Inner text with tags stripped; HTML entities left as Apex emitted them.
    text: []const u8,
};

/// Collect h1–h3 headings that have an `id` attribute, document order.
/// Slices point into `html` (or into `scratch` for stripped text when tags appear).
pub fn collectHeadings(
    allocator: std.mem.Allocator,
    html: []const u8,
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
        if (level < toc_min_level or level > toc_max_level) {
            // Skip to after this heading to avoid nested false matches.
            if (std.mem.indexOfPos(u8, html, open, "</h")) |close_h| {
                i = close_h + 1;
            } else {
                i = open + 3;
            }
            continue;
        }

        const gt = std.mem.indexOfPos(u8, html, open, ">") orelse break;
        const open_tag = html[open .. gt + 1];
        const id = extractIdAttr(open_tag) orelse {
            i = gt + 1;
            continue;
        };

        const close_pat = switch (level) {
            1 => "</h1>",
            2 => "</h2>",
            3 => "</h3>",
            else => unreachable,
        };
        const close = std.mem.indexOfPos(u8, html, gt + 1, close_pat) orelse {
            i = gt + 1;
            continue;
        };
        const inner = html[gt + 1 .. close];
        const text = try stripTags(allocator, inner);

        try out.append(allocator, .{
            .level = level,
            .id = id,
            .text = text,
        });
        i = close + close_pat.len;
    }
}

fn extractIdAttr(open_tag: []const u8) ?[]const u8 {
    // Prefer id="…"; accept id='…'.
    const key_dq = "id=\"";
    if (std.mem.indexOf(u8, open_tag, key_dq)) |at| {
        const start = at + key_dq.len;
        const end = std.mem.indexOfPos(u8, open_tag, start, "\"") orelse return null;
        if (end > start) return open_tag[start..end];
        return null;
    }
    const key_sq = "id='";
    if (std.mem.indexOf(u8, open_tag, key_sq)) |at| {
        const start = at + key_sq.len;
        const end = std.mem.indexOfPos(u8, open_tag, start, "'") orelse return null;
        if (end > start) return open_tag[start..end];
        return null;
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
            const end = std.mem.indexOfPos(u8, inner, i + 1, ">") orelse {
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

test "renderToc skips headings without id" {
    const gpa = std.testing.allocator;
    const toc = try renderToc(gpa, "<h2>No id</h2><h2 id=\"has\">Has</h2>");
    defer gpa.free(toc);
    try std.testing.expect(std.mem.indexOf(u8, toc, "href=\"#has\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, toc, "No id") == null);
}
