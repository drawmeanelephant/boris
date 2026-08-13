//! Closed HTML presentation for validated semantic relations.
//!
//! Relations are rendered from the frozen graph only. This module does not
//! parse author input, infer reciprocal edges, or expose a template query
//! language. The same small ordered views also provide page-local fingerprint
//! material for incremental HTML rendering.

const std = @import("std");
const graph_mod = @import("graph.zig");
const page_mod = @import("page.zig");
const identity = @import("identity.zig");
const html_nav = @import("html_nav.zig");

const RelationView = struct {
    source_index: u32,
    target_index: u32,
    kind: page_mod.RelationKind,
};

fn displayTitle(node: graph_mod.Node) []const u8 {
    return node.title orelse node.id;
}

fn outputPathFor(allocator: std.mem.Allocator, node: graph_mod.Node) ![]u8 {
    if (node.output_path.len > 0) return try allocator.dupe(u8, node.output_path);
    return try std.fmt.allocPrint(allocator, "{s}.html", .{node.id});
}

fn nodeIndex(nodes: []const graph_mod.Node, id: []const u8) ?u32 {
    for (nodes, 0..) |node, i| {
        if (std.mem.eql(u8, node.id, id)) return @intCast(i);
    }
    return null;
}

fn outgoingLess(nodes: []const graph_mod.Node, a: RelationView, b: RelationView) bool {
    const kind_order = std.mem.order(u8, a.kind.name(), b.kind.name());
    if (kind_order != .eq) return kind_order == .lt;
    return std.mem.order(u8, nodes[a.target_index].id, nodes[b.target_index].id) == .lt;
}

fn backlinkLess(nodes: []const graph_mod.Node, a: RelationView, b: RelationView) bool {
    const source_order = std.mem.order(u8, nodes[a.source_index].id, nodes[b.source_index].id);
    if (source_order != .eq) return source_order == .lt;
    return std.mem.order(u8, a.kind.name(), b.kind.name()) == .lt;
}

fn collectOutgoing(gpa: std.mem.Allocator, nodes: []const graph_mod.Node, current_index: u32) ![]RelationView {
    var views: std.ArrayList(RelationView) = .empty;
    errdefer views.deinit(gpa);
    for (nodes[current_index].semantic_relations) |relation| {
        const target = nodeIndex(nodes, relation.target) orelse continue;
        try views.append(gpa, .{ .source_index = current_index, .target_index = target, .kind = relation.kind });
    }
    std.mem.sort(RelationView, views.items, nodes, outgoingLess);
    return try views.toOwnedSlice(gpa);
}

fn collectBacklinks(gpa: std.mem.Allocator, nodes: []const graph_mod.Node, current_index: u32) ![]RelationView {
    var views: std.ArrayList(RelationView) = .empty;
    errdefer views.deinit(gpa);
    const current_id = nodes[current_index].id;
    for (nodes, 0..) |node, source_index| {
        for (node.semantic_relations) |relation| {
            if (std.mem.eql(u8, relation.target, current_id)) {
                try views.append(gpa, .{
                    .source_index = @intCast(source_index),
                    .target_index = current_index,
                    .kind = relation.kind,
                });
            }
        }
    }
    std.mem.sort(RelationView, views.items, nodes, backlinkLess);
    return try views.toOwnedSlice(gpa);
}

fn appendKindAttributes(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    kind: page_mod.RelationKind,
) !void {
    // RelationKind.parse guarantees this is a safe class token. Escaping the
    // attribute as well keeps this renderer defensive for graph unit fixtures.
    try buf.appendSlice(gpa, " data-relation-kind=\"");
    try html_nav.appendEscaped(buf, gpa, kind.name());
    try buf.appendSlice(gpa, "\" class=\"semantic-relation--");
    try buf.appendSlice(gpa, kind.name());
    try buf.appendSlice(gpa, "\"");
}

fn renderViewList(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    views: []const RelationView,
    current_output_path: []const u8,
    backlinks: bool,
) ![]u8 {
    if (views.len == 0) return "";
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    const section_class = if (backlinks) "semantic-backlinks" else "semantic-relations";
    const label = if (backlinks) "Backlinks" else "Semantic relations";
    try buf.appendSlice(allocator, "<section class=\"");
    try buf.appendSlice(allocator, section_class);
    try buf.appendSlice(allocator, "\" aria-label=\"");
    try buf.appendSlice(allocator, label);
    try buf.appendSlice(allocator, "\">\n<ul>\n");
    for (views) |view| {
        const linked_index = if (backlinks) view.source_index else view.target_index;
        const linked = nodes[linked_index];
        const out_path = try outputPathFor(allocator, linked);
        defer allocator.free(out_path);
        const href = try identity.relativeHref(allocator, current_output_path, out_path);
        defer allocator.free(href);
        try buf.appendSlice(allocator, "<li");
        try appendKindAttributes(&buf, allocator, view.kind);
        try buf.appendSlice(allocator, "><a href=\"");
        try html_nav.appendEscaped(&buf, allocator, href);
        try buf.appendSlice(allocator, "\">");
        try html_nav.appendEscaped(&buf, allocator, displayTitle(linked));
        try buf.appendSlice(allocator, "</a></li>\n");
    }
    try buf.appendSlice(allocator, "</ul>\n</section>");
    return try buf.toOwnedSlice(allocator);
}

pub fn renderRelations(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    const views = try collectOutgoing(allocator, nodes, current_index);
    defer allocator.free(views);
    return renderViewList(allocator, nodes, views, current_output_path, false);
}

pub fn renderBacklinks(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    current_index: u32,
    current_output_path: []const u8,
) ![]u8 {
    const views = try collectBacklinks(allocator, nodes, current_index);
    defer allocator.free(views);
    return renderViewList(allocator, nodes, views, current_output_path, true);
}

/// Stable page-local material for HTML fingerprints. It includes every value
/// that can affect a relation slot: direction, endpoint identity, kind, title,
/// and canonical output path. Pages without relation slots pass no material.
pub fn relationMaterial(
    allocator: std.mem.Allocator,
    nodes: []const graph_mod.Node,
    current_index: u32,
    include_outgoing: bool,
    include_backlinks: bool,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    if (include_outgoing) {
        const views = try collectOutgoing(allocator, nodes, current_index);
        defer allocator.free(views);
        for (views) |view| try appendMaterialLine(&buf, allocator, 'o', nodes, view, false);
    }
    if (include_backlinks) {
        const views = try collectBacklinks(allocator, nodes, current_index);
        defer allocator.free(views);
        for (views) |view| try appendMaterialLine(&buf, allocator, 'i', nodes, view, true);
    }
    return try buf.toOwnedSlice(allocator);
}

fn appendMaterialLine(
    buf: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    direction: u8,
    nodes: []const graph_mod.Node,
    view: RelationView,
    backlinks: bool,
) !void {
    const source = nodes[view.source_index];
    const target = nodes[view.target_index];
    const linked = if (backlinks) source else target;
    const linked_path = if (linked.output_path.len > 0) linked.output_path else linked.id;
    try buf.append(gpa, direction);
    for ([_][]const u8{ source.id, target.id, view.kind.name(), displayTitle(source), displayTitle(target), linked_path }) |part| {
        try buf.append(gpa, 0);
        try buf.appendSlice(gpa, part);
    }
    try buf.append(gpa, '\n');
}

test "semantic relation views sort and derive backlinks" {
    const gpa = std.testing.allocator;
    const kind_a = page_mod.RelationKind.parse("implements").?;
    const kind_b = page_mod.RelationKind.parse("verified_by").?;
    const nodes = [_]graph_mod.Node{
        .{ .id = "guides/deep/source", .source_path = "source.md", .output_path = "guides/deep/source.html", .semantic_relations = &.{ .{ .kind = kind_b, .target = "reference/target" }, .{ .kind = kind_a, .target = "reference/target" } } },
        .{ .id = "reference/target", .source_path = "target.md", .output_path = "reference/target.html", .title = "Target" },
    };
    const outgoing = try renderRelations(gpa, &nodes, 0, nodes[0].output_path);
    defer gpa.free(outgoing);
    try std.testing.expect(std.mem.indexOf(u8, outgoing, "data-relation-kind=\"implements\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, outgoing, "href=\"../../reference/target.html\"") != null);
    const backlinks = try renderBacklinks(gpa, &nodes, 1, nodes[1].output_path);
    defer gpa.free(backlinks);
    try std.testing.expect(std.mem.indexOf(u8, backlinks, "semantic-backlinks") != null);
    try std.testing.expect(std.mem.indexOf(u8, backlinks, "href=\"../guides/deep/source.html\"") != null);
}
