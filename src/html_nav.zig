//! Feature 6 — HTML chrome from a frozen Trunk/Satellite graph.
//!
//! Renders deterministic `{{nav}}` (full site forest) and `{{breadcrumb}}`
//! fragments plus escaped `{{title}}` text. All output is allocated on the
//! caller-provided allocator (typically the document Whiteboard).

const std = @import("std");
const graph_mod = @import("graph.zig");
const identity = @import("identity.zig");
const diag = @import("diag.zig");

/// Append HTML-escaped text (`& < > "`).
pub fn appendEscaped(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '&' => try buf.appendSlice(allocator, "&amp;"),
            '<' => try buf.appendSlice(allocator, "&lt;"),
            '>' => try buf.appendSlice(allocator, "&gt;"),
            '"' => try buf.appendSlice(allocator, "&quot;"),
            else => try buf.append(allocator, c),
        }
    }
}

fn displayTitle(node: graph_mod.Node) []const u8 {
    return node.title orelse node.id;
}

fn outputPathFor(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.html", .{node.id});
}

/// Stable site-nav fingerprint material: ordered `(id, title, parent, role)` lines.
pub fn siteNavMaterial(allocator: std.mem.Allocator, nodes: []const graph_mod.Node) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    for (nodes) |n| {
        try buf.appendSlice(allocator, n.id);
        try buf.append(allocator, 0);
        try buf.appendSlice(allocator, n.title orelse "");
        try buf.append(allocator, 0);
        try buf.appendSlice(allocator, n.parent orelse "");
        try buf.append(allocator, 0);
        try buf.appendSlice(allocator, n.role.name());
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

/// Full site forest for `{{nav}}`.
pub fn renderNav(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<nav class=\"site-nav\" aria-label=\"Site\">\n<ul>\n");

    for (nodes, 0..) |node, i| {
        if (node.parent != null) continue; // trunks only (id order among frozen nodes)
        const idx: u32 = @intCast(i);
        const out_path = try outputPathFor(allocator, node);
        defer allocator.free(out_path);
        const href = try identity.relativeHref(allocator, current_output_path, out_path);
        defer allocator.free(href);

        try buf.appendSlice(allocator, "<li class=\"site-nav__trunk");
        if (idx == current_index) try buf.appendSlice(allocator, " is-current");
        try buf.appendSlice(allocator, "\"><a href=\"");
        try appendEscaped(&buf, allocator, href);
        try buf.appendSlice(allocator, "\"");
        if (idx == current_index) try buf.appendSlice(allocator, " aria-current=\"page\"");
        try buf.appendSlice(allocator, ">");
        try appendEscaped(&buf, allocator, displayTitle(node));
        try buf.appendSlice(allocator, "</a>");

        const children = nav[i].children;
        if (children.len > 0) {
            try buf.appendSlice(allocator, "\n<ul>\n");
            for (children) |ci| {
                const child = nodes[ci];
                const child_out = try outputPathFor(allocator, child);
                defer allocator.free(child_out);
                const child_href = try identity.relativeHref(allocator, current_output_path, child_out);
                defer allocator.free(child_href);
                try buf.appendSlice(allocator, "<li class=\"site-nav__satellite");
                if (ci == current_index) try buf.appendSlice(allocator, " is-current");
                try buf.appendSlice(allocator, "\"><a href=\"");
                try appendEscaped(&buf, allocator, child_href);
                try buf.appendSlice(allocator, "\"");
                if (ci == current_index) try buf.appendSlice(allocator, " aria-current=\"page\"");
                try buf.appendSlice(allocator, ">");
                try appendEscaped(&buf, allocator, displayTitle(child));
                try buf.appendSlice(allocator, "</a></li>\n");
            }
            try buf.appendSlice(allocator, "</ul>\n");
        }
        try buf.appendSlice(allocator, "</li>\n");
    }

    try buf.appendSlice(allocator, "</ul>\n</nav>");
    return try buf.toOwnedSlice(allocator);
}

/// Direct frozen children for `{{children}}`. Satellites have no children in
/// Boris's one-level Trunk/Satellite graph, so their fragment is empty.
pub fn renderChildren(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    const children = nav[current_index].children;
    if (children.len == 0) return "";

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<nav class=\"page-children\" aria-label=\"Children\">\n<ul>\n");
    for (children) |ci| {
        const child = nodes[ci];
        const output_path = try outputPathFor(allocator, child);
        defer allocator.free(output_path);
        const href = try identity.relativeHref(allocator, current_output_path, output_path);
        defer allocator.free(href);
        try buf.appendSlice(allocator, "<li><a href=\"");
        try appendEscaped(&buf, allocator, href);
        try buf.appendSlice(allocator, "\">");
        try appendEscaped(&buf, allocator, displayTitle(child));
        try buf.appendSlice(allocator, "</a></li>\n");
    }
    try buf.appendSlice(allocator, "</ul>\n</nav>");
    return try buf.toOwnedSlice(allocator);
}

/// Breadcrumb root → self for `{{breadcrumb}}`.
pub fn renderBreadcrumb(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "<nav class=\"breadcrumb\" aria-label=\"Breadcrumb\">\n<ol>\n");

    const crumb = nav[current_index].breadcrumb;
    for (crumb, 0..) |ni, i| {
        const node = nodes[ni];
        const is_last = i + 1 == crumb.len;
        if (is_last) {
            try buf.appendSlice(allocator, "<li aria-current=\"page\">");
            try appendEscaped(&buf, allocator, displayTitle(node));
            try buf.appendSlice(allocator, "</li>\n");
        } else {
            const out_path = try outputPathFor(allocator, node);
            defer allocator.free(out_path);
            const href = try identity.relativeHref(allocator, current_output_path, out_path);
            defer allocator.free(href);
            try buf.appendSlice(allocator, "<li><a href=\"");
            try appendEscaped(&buf, allocator, href);
            try buf.appendSlice(allocator, "\">");
            try appendEscaped(&buf, allocator, displayTitle(node));
            try buf.appendSlice(allocator, "</a></li>\n");
        }
    }

    try buf.appendSlice(allocator, "</ol>\n</nav>");
    return try buf.toOwnedSlice(allocator);
}

/// Escaped page title text for `{{title}}`.
pub fn renderTitle(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendEscaped(&buf, allocator, displayTitle(node));
    return try buf.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "appendEscaped escapes markup" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try appendEscaped(&buf, gpa, "a<b>&\"c");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;c", buf.items);
}

test "renderNav forest and breadcrumb" {
    const gpa = std.testing.allocator;
    var nodes = [_]graph_mod.Node{
        .{ .id = "guides/intro", .source_path = "guides/intro.md", .title = "Intro", .parent = null },
        .{ .id = "guides/tips", .source_path = "guides/tips.md", .title = "Tips", .parent = "guides/intro" },
        .{ .id = "index", .source_path = "index.md", .title = "Home", .parent = null },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try graph_mod.validate(gpa, gpa, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    const g = try graph_mod.freeze(gpa, &nodes, null);
    defer gpa.free(g.edges);
    const nav = try graph_mod.buildNav(gpa, g.nodes);
    defer graph_mod.freeNav(gpa, nav);

    var tips_i: u32 = 0;
    for (g.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, "guides/tips")) tips_i = @intCast(i);
    }
    const html = try renderNav(gpa, g.nodes, nav, tips_i, "guides/tips.html");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "is-current") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "../index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"intro.html\"") != null);

    const crumb = try renderBreadcrumb(gpa, g.nodes, nav, tips_i, "guides/tips.html");
    defer gpa.free(crumb);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "breadcrumb") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "aria-current=\"page\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "Tips") != null);
}

test "renderChildren is id-sorted, escaped, relative, and empty for satellite" {
    const gpa = std.testing.allocator;
    var nodes = [_]graph_mod.Node{
        .{ .id = "zeta", .source_path = "zeta.md", .parent = "index" },
        .{ .id = "index", .source_path = "index.md" },
        .{ .id = "alpha", .source_path = "alpha.md", .title = "A & <Alpha> \"quoted\"", .parent = "index" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try graph_mod.validate(gpa, gpa, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    const g = try graph_mod.freeze(gpa, &nodes, null);
    defer gpa.free(g.edges);
    const nav = try graph_mod.buildNav(gpa, g.nodes);
    defer graph_mod.freeNav(gpa, nav);

    const parent = try renderChildren(gpa, g.nodes, nav, 1, "index.html");
    defer gpa.free(parent);
    try std.testing.expect(std.mem.indexOf(u8, parent, "page-children") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"alpha.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "A &amp; &lt;Alpha&gt; &quot;quoted&quot;") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "href=\"zeta.html\">zeta") != null);
    try std.testing.expect(std.mem.indexOf(u8, parent, "alpha.html").? < std.mem.indexOf(u8, parent, "zeta.html").?);

    const satellite = try renderChildren(gpa, g.nodes, nav, 0, "alpha.html");
    try std.testing.expectEqualStrings("", satellite);
}

test "navigation chrome has deterministic landmarks, lists, current state, and escaped sinks" {
    const gpa = std.testing.allocator;
    var nodes = [_]graph_mod.Node{
        .{ .id = "index", .source_path = "index.md", .title = "Home & <Start> \"quoted\"", .parent = null },
        .{ .id = "guides/intro", .source_path = "guides/intro.md", .title = "Intro", .parent = "index" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try graph_mod.validate(gpa, gpa, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    const g = try graph_mod.freeze(gpa, &nodes, null);
    defer gpa.free(g.edges);
    const nav = try graph_mod.buildNav(gpa, g.nodes);
    defer graph_mod.freeNav(gpa, nav);

    var current: u32 = 0;
    for (g.nodes, 0..) |node, i| {
        if (std.mem.eql(u8, node.id, "index")) current = @intCast(i);
    }
    const site = try renderNav(gpa, g.nodes, nav, current, "index.html");
    defer gpa.free(site);
    try std.testing.expectEqualStrings(
        "<nav class=\"site-nav\" aria-label=\"Site\">\n" ++
            "<ul>\n" ++
            "<li class=\"site-nav__trunk is-current\"><a href=\"index.html\" aria-current=\"page\">Home &amp; &lt;Start&gt; &quot;quoted&quot;</a>\n" ++
            "<ul>\n" ++
            "<li class=\"site-nav__satellite\"><a href=\"guides/intro.html\">Intro</a></li>\n" ++
            "</ul>\n" ++
            "</li>\n" ++
            "</ul>\n" ++
            "</nav>",
        site,
    );

    const children = try renderChildren(gpa, g.nodes, nav, current, "index.html");
    defer gpa.free(children);
    try std.testing.expectEqualStrings(
        "<nav class=\"page-children\" aria-label=\"Children\">\n" ++
            "<ul>\n" ++
            "<li><a href=\"guides/intro.html\">Intro</a></li>\n" ++
            "</ul>\n" ++
            "</nav>",
        children,
    );

    const crumb = try renderBreadcrumb(gpa, g.nodes, nav, current, "index.html");
    defer gpa.free(crumb);
    try std.testing.expectEqualStrings(
        "<nav class=\"breadcrumb\" aria-label=\"Breadcrumb\">\n" ++
            "<ol>\n" ++
            "<li aria-current=\"page\">Home &amp; &lt;Start&gt; &quot;quoted&quot;</li>\n" ++
            "</ol>\n" ++
            "</nav>",
        crumb,
    );

    const title = try renderTitle(gpa, g.nodes[current]);
    defer gpa.free(title);
    try std.testing.expectEqualStrings("Home &amp; &lt;Start&gt; &quot;quoted&quot;", title);
}
