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

/// A `status: draft` page is emitted but not advertised (#738): it and its
/// whole subtree are pruned from `{{nav}}`, and it is omitted from
/// `{{children}}`. Archived and unset statuses stay advertised.
fn isDraft(node: graph_mod.Node) bool {
    return node.status != null and std.mem.eql(u8, node.status.?, "draft");
}

fn outputPathFor(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{s}.html", .{node.id});
}

/// Stable site-nav fingerprint material: ordered `(id, title, parent, role, status)` lines.
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
        try buf.append(allocator, 0);
        // Status is load-bearing for nav bytes (#738): a draft flip changes
        // what `{{nav}}` / `{{children}}` render, so it must dirty chrome.
        try buf.appendSlice(allocator, n.status orelse "");
        try buf.append(allocator, '\n');
    }
    return try buf.toOwnedSlice(allocator);
}

fn breadcrumbContains(nav: []const graph_mod.NavEntry, current_index: u32, index: u32) bool {
    for (nav[current_index].breadcrumb) |crumb| {
        if (crumb == index) return true;
    }
    return false;
}

fn appendNavNode(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    index: u32,
    current_index: u32,
    current_output_path: []const u8,
    is_root: bool,
) !void {
    const node = nodes[index];
    const out_path = try outputPathFor(allocator, node);
    defer allocator.free(out_path);
    const href = try identity.relativeHref(allocator, current_output_path, out_path);
    defer allocator.free(href);
    const is_current = index == current_index;
    const is_ancestor = !is_current and breadcrumbContains(nav, current_index, index);

    try buf.appendSlice(allocator, "<li class=\"");
    try buf.appendSlice(allocator, if (is_root) "site-nav__trunk" else "site-nav__satellite");
    if (is_current) try buf.appendSlice(allocator, " is-current");
    if (is_ancestor) try buf.appendSlice(allocator, " is-ancestor");
    try buf.appendSlice(allocator, "\"><a href=\"");
    try appendEscaped(buf, allocator, href);
    try buf.appendSlice(allocator, "\"");
    if (is_current) try buf.appendSlice(allocator, " aria-current=\"page\"");
    try buf.appendSlice(allocator, ">");
    try appendEscaped(buf, allocator, displayTitle(node));
    try buf.appendSlice(allocator, "</a>");

    const children = nav[index].children;
    // Open a nested list only when at least one child survives pruning, so an
    // all-draft child set never leaves an empty (invalid) <ul> behind (#738).
    var any_advertised = false;
    for (children) |ci| {
        if (!isDraft(nodes[ci])) {
            any_advertised = true;
            break;
        }
    }
    if (any_advertised) {
        try buf.appendSlice(allocator, "\n<ul>\n");
        for (children) |child_index| {
            // Prune draft-rooted subtrees: skipping the child skips everything
            // below it, so a published satellite under a draft section stays
            // emitted but unadvertised until its parent publishes (#738).
            if (isDraft(nodes[child_index])) continue;
            try appendNavNode(allocator, buf, nodes, nav, child_index, current_index, current_output_path, false);
        }
        try buf.appendSlice(allocator, "</ul>\n");
    }
    try buf.appendSlice(allocator, "</li>\n");
}

/// Full site forest for `{{nav}}`, recursively rendering the frozen hierarchy.
/// Draft-rooted subtrees are pruned; the empty wrapper still emits when every
/// trunk is drafted.
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
        if (isDraft(node)) continue; // draft trunks are not advertised (#738)
        try appendNavNode(allocator, &buf, nodes, nav, @intCast(i), current_index, current_output_path, true);
    }

    try buf.appendSlice(allocator, "</ul>\n</nav>");
    return try buf.toOwnedSlice(allocator);
}

/// Direct frozen children for `{{children}}`. Draft children are omitted;
/// an all-draft or empty child list emits the empty fragment.
pub fn renderChildren(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    nav: []const graph_mod.NavEntry,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    const children = nav[current_index].children;
    var any_advertised = false;
    for (children) |ci| {
        if (!isDraft(nodes[ci])) {
            any_advertised = true;
            break;
        }
    }
    if (!any_advertised) return "";

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, "<nav class=\"page-children\" aria-label=\"Children\">\n<ul>\n");
    for (children) |ci| {
        if (isDraft(nodes[ci])) continue;
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
        .{ .id = "guides/tips/deep", .source_path = "guides/tips/deep.md", .title = "Deep Tips", .parent = "guides/tips" },
        .{ .id = "guides/tips/deep/deepest", .source_path = "guides/tips/deep/deepest.md", .title = "Deepest Tips", .parent = "guides/tips/deep" },
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

    var deepest_i: u32 = 0;
    for (g.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, "guides/tips/deep/deepest")) deepest_i = @intCast(i);
    }
    const html = try renderNav(gpa, g.nodes, nav, deepest_i, "guides/tips/deep/deepest.html");
    defer gpa.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "site-nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "is-current") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "../../index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"../../intro.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"../deep.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"deepest.html\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "site-nav__satellite is-ancestor") != null);

    const crumb = try renderBreadcrumb(gpa, g.nodes, nav, deepest_i, "guides/tips/deep/deepest.html");
    defer gpa.free(crumb);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "breadcrumb") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "aria-current=\"page\"") != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, crumb, "<li"));
    try std.testing.expect(std.mem.indexOf(u8, crumb, "Intro") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "Tips") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "Deep Tips") != null);
    try std.testing.expect(std.mem.indexOf(u8, crumb, "Deepest Tips") != null);
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

test "draft-rooted subtrees are pruned from nav and omitted from children" {
    const gpa = std.testing.allocator;
    var nodes = [_]graph_mod.Node{
        .{ .id = "alpha", .source_path = "alpha.md", .title = "Alpha", .parent = null },
        // Draft trunk: pruned together with its published satellite.
        .{ .id = "beta", .source_path = "beta.md", .title = "Beta", .parent = null, .status = "draft" },
        .{ .id = "beta/child", .source_path = "beta/child.md", .title = "Beta Child", .parent = "beta" },
        // Archived trunk stays advertised.
        .{ .id = "gamma", .source_path = "gamma.md", .title = "Gamma", .parent = null, .status = "archived" },
        // Published trunk with a drafted satellite between two live ones.
        .{ .id = "index", .source_path = "index.md", .title = "Home", .parent = null },
        .{ .id = "index/draft-kid", .source_path = "index/draft-kid.md", .title = "Hidden", .parent = "index", .status = "draft" },
        .{ .id = "index/live-kid", .source_path = "index/live-kid.md", .title = "Shown", .parent = "index" },
        // Archived trunk whose only child is drafted: all-draft child list.
        .{ .id = "gamma/hush", .source_path = "gamma/hush.md", .title = "Hush", .parent = "gamma", .status = "draft" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try graph_mod.validate(gpa, gpa, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    const g = try graph_mod.freeze(gpa, &nodes, null);
    defer gpa.free(g.edges);
    const nav = try graph_mod.buildNav(gpa, g.nodes);
    defer graph_mod.freeNav(gpa, nav);

    var index_i: u32 = 0;
    for (g.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, "index")) index_i = @intCast(i);
    }

    const site = try renderNav(gpa, g.nodes, nav, index_i, "index.html");
    defer gpa.free(site);
    try std.testing.expect(std.mem.indexOf(u8, site, ">Alpha</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, site, ">Gamma</a>") != null);
    // An advertised page whose children are all drafts emits no empty <ul>.
    try std.testing.expect(std.mem.indexOf(u8, site, ">Gamma</a>\n<ul>") == null);
    try std.testing.expect(std.mem.indexOf(u8, site, "<ul>\n</ul>") == null);
    try std.testing.expect(std.mem.indexOf(u8, site, "beta.html") == null);
    try std.testing.expect(std.mem.indexOf(u8, site, "Beta Child") == null);
    try std.testing.expect(std.mem.indexOf(u8, site, ">Shown</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, site, "Hidden") == null);

    const kids = try renderChildren(gpa, g.nodes, nav, index_i, "index.html");
    defer gpa.free(kids);
    try std.testing.expect(std.mem.indexOf(u8, kids, ">Shown</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, kids, "draft-kid") == null);

    // An all-draft child list emits the empty fragment, not an empty wrapper.
    var gamma_i: u32 = 0;
    for (g.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, "gamma")) gamma_i = @intCast(i);
    }
    const none = try renderChildren(gpa, g.nodes, nav, gamma_i, "gamma.html");
    try std.testing.expectEqualStrings("", none);

    // Fingerprint material carries status so a draft flip dirties chrome.
    const material_a = try siteNavMaterial(gpa, g.nodes);
    defer gpa.free(material_a);
    var draft_kid_i: u32 = 0;
    for (g.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, "index/draft-kid")) draft_kid_i = @intCast(i);
    }
    g.nodes[draft_kid_i].status = "published";
    const material_b = try siteNavMaterial(gpa, g.nodes);
    defer gpa.free(material_b);
    try std.testing.expect(!std.mem.eql(u8, material_a, material_b));
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
