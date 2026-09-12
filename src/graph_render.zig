//! Deterministic text renders of the frozen content graph.
//!
//! `boris graph --format mermaid|dot` consumes the already-validated,
//! already-frozen graph from `pipeline.compile` and emits one text document.
//! Nothing here resolves parents, re-parses frontmatter, or invents edges:
//! aliases, labels, and edge styles are projections of the frozen node and
//! dependency arrays, so the render cannot disagree with `graph.json`.
//!
//! Escaping is not local. Label bytes go through `structured_out.Sink` and the
//! `mermaid_label` / `dot_label` targets in `encode.zig`, so page-controlled
//! titles cannot close a label or inject diagram markup (see
//! `emitter_discipline_test.zig`).
//!
//! Output is deterministic for the same frozen graph: page order and edge
//! order are the canonical frozen orders, source endpoints are alias-sorted,
//! and no file name, path, or timestamp enters the document.

const std = @import("std");
const graph_mod = @import("graph.zig");
const pipeline = @import("pipeline.zig");
const structured_out = @import("structured_out.zig");

const Sink = structured_out.Sink;

pub const Format = enum { mermaid, dot };

pub const Error = error{UnknownEndpoint};

/// Render the frozen graph. `pages` and `edges` are the canonical frozen
/// arrays from `pipeline.Result`; callers must not hand over a provisional
/// graph. Returns an owned slice.
pub fn render(
    gpa: std.mem.Allocator,
    pages: []const graph_mod.Node,
    edges: []const pipeline.DependencyEdge,
    format: Format,
) ![]u8 {
    var tables = Tables{};
    defer tables.deinit(gpa);
    try tables.build(gpa, pages, edges);
    var relations: std.ArrayListUnmanaged(RelationEdge) = .empty;
    defer relations.deinit(gpa);
    try collectRelations(gpa, pages, &tables, &relations);
    std.mem.sort(RelationEdge, relations.items, {}, relationLess);

    return switch (format) {
        .mermaid => renderMermaid(gpa, pages, edges, relations.items, &tables),
        .dot => renderDot(gpa, pages, edges, relations.items, &tables),
    };
}

/// Node alias tables. Pages keep their frozen index (`p<i>`, id-sorted);
/// `source` endpoints are not page nodes and get their own alias space
/// (`s<i>`) assigned in canonical byte order.
const Tables = struct {
    page_alias: std.StringHashMapUnmanaged(u32) = .empty,
    source_alias: std.StringHashMapUnmanaged(u32) = .empty,
    source_order: std.ArrayListUnmanaged([]const u8) = .empty,
    seen_sources: std.StringHashMapUnmanaged(void) = .empty,

    fn deinit(self: *Tables, gpa: std.mem.Allocator) void {
        self.page_alias.deinit(gpa);
        self.source_alias.deinit(gpa);
        self.source_order.deinit(gpa);
        self.seen_sources.deinit(gpa);
    }

    fn build(self: *Tables, gpa: std.mem.Allocator, pages: []const graph_mod.Node, edges: []const pipeline.DependencyEdge) !void {
        for (pages, 0..) |node, index| {
            try self.page_alias.put(gpa, node.id, @intCast(index));
        }
        for (edges) |edge| {
            try self.noteSource(gpa, edge.from);
            try self.noteSource(gpa, edge.to);
        }
        std.mem.sort([]const u8, self.source_order.items, {}, strLess);
        for (self.source_order.items, 0..) |value, index| {
            try self.source_alias.put(gpa, value, @intCast(index));
        }
    }

    fn noteSource(self: *Tables, gpa: std.mem.Allocator, endpoint: pipeline.Endpoint) !void {
        if (endpoint.type != .source) return;
        const entry = try self.seen_sources.getOrPut(gpa, endpoint.value);
        if (entry.found_existing) return;
        try self.source_order.append(gpa, endpoint.value);
    }

    fn alias(self: *const Tables, endpoint: pipeline.Endpoint) Error!Alias {
        const index = switch (endpoint.type) {
            .page => self.page_alias.get(endpoint.value) orelse return error.UnknownEndpoint,
            .source => self.source_alias.get(endpoint.value) orelse return error.UnknownEndpoint,
        };
        return switch (endpoint.type) {
            .page => .{ .page = index },
            .source => .{ .source = index },
        };
    }
};

const Alias = union(enum) {
    page: u32,
    source: u32,
};

const RelationEdge = struct {
    from: u32,
    to: u32,
    kind: []const u8,
};

fn strLess(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

fn relationLess(_: void, left: RelationEdge, right: RelationEdge) bool {
    if (left.from != right.from) return left.from < right.from;
    if (left.to != right.to) return left.to < right.to;
    return std.mem.order(u8, left.kind, right.kind) == .lt;
}

/// Author semantic relations, projected from the frozen nodes and sorted by
/// source index, then target index, then kind — index order is id order, so
/// this matches the IR relation ordering.
fn collectRelations(
    gpa: std.mem.Allocator,
    pages: []const graph_mod.Node,
    tables: *const Tables,
    out: *std.ArrayListUnmanaged(RelationEdge),
) !void {
    for (pages, 0..) |node, index| {
        for (node.semantic_relations) |relation| {
            const target = tables.page_alias.get(relation.target) orelse return error.UnknownEndpoint;
            try out.append(gpa, .{
                .from = @intCast(index),
                .to = target,
                .kind = relation.kind.name(),
            });
        }
    }
}

fn pageLabel(node: graph_mod.Node) []const u8 {
    if (node.title) |title| if (title.len > 0) return title;
    return node.id;
}

fn appendAlias(out: *Sink, alias: Alias) !void {
    switch (alias) {
        .page => |index| {
            try out.lit("p");
            try out.num(index);
        },
        .source => |index| {
            try out.lit("s");
            try out.num(index);
        },
    }
}

fn appendRoleClass(out: *Sink, role: graph_mod.Role) !void {
    switch (role) {
        .trunk => try out.lit("trunk"),
        .satellite => try out.lit("satellite"),
    }
}

fn isKind(kind: []const u8, comptime name: []const u8) bool {
    return std.mem.eql(u8, kind, name);
}

fn renderMermaid(
    gpa: std.mem.Allocator,
    pages: []const graph_mod.Node,
    edges: []const pipeline.DependencyEdge,
    relations: []const RelationEdge,
    tables: *const Tables,
) ![]u8 {
    var out = Sink.init(gpa);
    errdefer out.deinit();

    try out.lit("graph TD\n");
    try out.lit("  %% boris graph --format mermaid\n");
    try out.lit("  classDef trunk stroke:#2563eb,stroke-width:2px;\n");
    try out.lit("  classDef satellite stroke:#6b7280;\n");
    try out.lit("  classDef source stroke:#9ca3af,stroke-dasharray:4 3;\n");

    for (pages, 0..) |node, index| {
        try out.lit("  p");
        try out.num(index);
        try out.lit("[\"");
        try out.field(.mermaid_label, pageLabel(node));
        try out.lit("\"]:::");
        try appendRoleClass(&out, node.role);
        try out.lit("\n");
    }
    for (tables.source_order.items, 0..) |value, index| {
        try out.lit("  s");
        try out.num(index);
        try out.lit("[\"");
        try out.field(.mermaid_label, value);
        try out.lit("\"]:::source\n");
    }

    for (edges) |edge| {
        const from = try tables.alias(edge.from);
        const to = try tables.alias(edge.to);
        try out.lit("  ");
        if (isKind(edge.kind, "parent")) {
            // The authored edge is the satellite's dependency on its parent;
            // the diagram draws the hierarchy parent → child.
            try appendAlias(&out, to);
            try out.lit(" --> ");
            try appendAlias(&out, from);
        } else if (isKind(edge.kind, "include")) {
            try appendAlias(&out, from);
            try out.lit(" ==> ");
            try appendAlias(&out, to);
        } else if (isKind(edge.kind, "reference")) {
            try appendAlias(&out, from);
            try out.lit(" -.-> ");
            try appendAlias(&out, to);
        } else {
            try appendAlias(&out, from);
            try out.lit(" --> ");
            try appendAlias(&out, to);
        }
        try out.lit("\n");
    }

    for (relations) |relation| {
        try out.lit("  p");
        try out.num(relation.from);
        try out.lit(" -->|");
        try out.field(.mermaid_label, relation.kind);
        try out.lit("| p");
        try out.num(relation.to);
        try out.lit("\n");
    }

    return out.toOwnedSlice();
}

fn renderDot(
    gpa: std.mem.Allocator,
    pages: []const graph_mod.Node,
    edges: []const pipeline.DependencyEdge,
    relations: []const RelationEdge,
    tables: *const Tables,
) ![]u8 {
    var out = Sink.init(gpa);
    errdefer out.deinit();

    try out.lit("digraph boris {\n");
    try out.lit("  rankdir=TD;\n");
    try out.lit("  node [shape=box];\n");

    for (pages, 0..) |node, index| {
        try out.lit("  p");
        try out.num(index);
        try out.lit(" [label=\"");
        try out.field(.dot_label, pageLabel(node));
        try out.lit("\", class=\"");
        try appendRoleClass(&out, node.role);
        try out.lit("\"];\n");
    }
    for (tables.source_order.items, 0..) |value, index| {
        try out.lit("  s");
        try out.num(index);
        try out.lit(" [label=\"");
        try out.field(.dot_label, value);
        try out.lit("\", shape=note, class=\"source\"];\n");
    }

    for (edges) |edge| {
        const from = try tables.alias(edge.from);
        const to = try tables.alias(edge.to);
        try out.lit("  ");
        if (isKind(edge.kind, "parent")) {
            // See renderMermaid: hierarchy reads parent → child.
            try appendAlias(&out, to);
            try out.lit(" -> ");
            try appendAlias(&out, from);
            try out.lit(";\n");
        } else if (isKind(edge.kind, "include")) {
            try appendAlias(&out, from);
            try out.lit(" -> ");
            try appendAlias(&out, to);
            try out.lit(" [style=bold];\n");
        } else if (isKind(edge.kind, "reference")) {
            try appendAlias(&out, from);
            try out.lit(" -> ");
            try appendAlias(&out, to);
            try out.lit(" [style=dotted];\n");
        } else {
            try appendAlias(&out, from);
            try out.lit(" -> ");
            try appendAlias(&out, to);
            try out.lit(";\n");
        }
    }

    for (relations) |relation| {
        try out.lit("  p");
        try out.num(relation.from);
        try out.lit(" -> p");
        try out.num(relation.to);
        try out.lit(" [label=\"");
        try out.field(.dot_label, relation.kind);
        try out.lit("\"];\n");
    }

    try out.lit("}\n");
    return out.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn ep(kind: pipeline.EndpointType, value: []const u8) pipeline.Endpoint {
    return .{ .type = kind, .value = value };
}

fn link(from: pipeline.Endpoint, to: pipeline.Endpoint, kind: []const u8) pipeline.DependencyEdge {
    return .{ .from = from, .to = to, .kind = kind };
}

/// The canonical acceptance topology: a parent link, an include to a source
/// endpoint, a reference from the source fragment back to a page, a page
/// reference, and one semantic relation with a quoted title.
const acceptance_pages = [_]graph_mod.Node{
    .{
        .index = 0,
        .id = "guides/child",
        .source_path = "guides/child.md",
        .title = "Child Page",
        .parent = "index",
        .role = .satellite,
        .semantic_relations = &.{.{ .kind = .{ .value = "supersedes" }, .target = "guides/target" }},
    },
    .{
        .index = 1,
        .id = "guides/target",
        .source_path = "guides/target.md",
        .title = "Target \"Page\"",
        .role = .trunk,
    },
    .{
        .index = 2,
        .id = "index",
        .source_path = "index.md",
        .title = null,
        .role = .trunk,
    },
};

const acceptance_edges = [_]pipeline.DependencyEdge{
    link(ep(.page, "guides/child"), ep(.page, "index"), "parent"),
    link(ep(.page, "index"), ep(.page, "guides/target"), "reference"),
    link(ep(.page, "index"), ep(.source, "includes/shared.md"), "include"),
    link(ep(.source, "includes/shared.md"), ep(.page, "guides/target"), "reference"),
};

const acceptance_mermaid =
    \\graph TD
    \\  %% boris graph --format mermaid
    \\  classDef trunk stroke:#2563eb,stroke-width:2px;
    \\  classDef satellite stroke:#6b7280;
    \\  classDef source stroke:#9ca3af,stroke-dasharray:4 3;
    \\  p0["Child Page"]:::satellite
    \\  p1["Target #quot;Page#quot;"]:::trunk
    \\  p2["index"]:::trunk
    \\  s0["includes/shared.md"]:::source
    \\  p2 --> p0
    \\  p2 -.-> p1
    \\  p2 ==> s0
    \\  s0 -.-> p1
    \\  p0 -->|supersedes| p1
    \\
;

const acceptance_dot =
    \\digraph boris {
    \\  rankdir=TD;
    \\  node [shape=box];
    \\  p0 [label="Child Page", class="satellite"];
    \\  p1 [label="Target \"Page\"", class="trunk"];
    \\  p2 [label="index", class="trunk"];
    \\  s0 [label="includes/shared.md", shape=note, class="source"];
    \\  p2 -> p0;
    \\  p2 -> p1 [style=dotted];
    \\  p2 -> s0 [style=bold];
    \\  s0 -> p1 [style=dotted];
    \\  p0 -> p1 [label="supersedes"];
    \\}
    \\
;

test "mermaid render pins the acceptance topology" {
    const got = try render(std.testing.allocator, &acceptance_pages, &acceptance_edges, .mermaid);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(acceptance_mermaid, got);
}

test "dot render pins the acceptance topology" {
    const got = try render(std.testing.allocator, &acceptance_pages, &acceptance_edges, .dot);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(acceptance_dot, got);
}

test "renders are deterministic across repeated calls" {
    const gpa = std.testing.allocator;
    const first = try render(gpa, &acceptance_pages, &acceptance_edges, .mermaid);
    defer gpa.free(first);
    const second = try render(gpa, &acceptance_pages, &acceptance_edges, .mermaid);
    defer gpa.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "source endpoints are alias-sorted, not edge-discovery ordered" {
    const gpa = std.testing.allocator;
    const pages = [_]graph_mod.Node{
        .{ .index = 0, .id = "index", .source_path = "index.md", .title = "Index", .role = .trunk },
    };
    // Reverse discovery order: `zeta` is seen first.
    const edges = [_]pipeline.DependencyEdge{
        link(ep(.page, "index"), ep(.source, "zeta.md"), "include"),
        link(ep(.page, "index"), ep(.source, "alpha.md"), "include"),
    };
    const got = try render(gpa, &pages, &edges, .mermaid);
    defer gpa.free(got);
    try std.testing.expect(std.mem.indexOf(u8, got, "s0[\"alpha.md\"]:::source") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "s1[\"zeta.md\"]:::source") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "p0 ==> s0") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "p0 ==> s1") != null);
}

test "empty graph still emits a valid document" {
    const gpa = std.testing.allocator;
    const mermaid = try render(gpa, &.{}, &.{}, .mermaid);
    defer gpa.free(mermaid);
    try std.testing.expectEqualStrings(
        "graph TD\n  %% boris graph --format mermaid\n" ++
            "  classDef trunk stroke:#2563eb,stroke-width:2px;\n" ++
            "  classDef satellite stroke:#6b7280;\n" ++
            "  classDef source stroke:#9ca3af,stroke-dasharray:4 3;\n",
        mermaid,
    );
    const dot = try render(gpa, &.{}, &.{}, .dot);
    defer gpa.free(dot);
    try std.testing.expectEqualStrings("digraph boris {\n  rankdir=TD;\n  node [shape=box];\n}\n", dot);
}

test "unknown endpoints are rejected, never silently dropped" {
    const gpa = std.testing.allocator;
    const pages = [_]graph_mod.Node{
        .{ .index = 0, .id = "index", .source_path = "index.md", .role = .trunk },
    };
    const edges = [_]pipeline.DependencyEdge{
        link(ep(.page, "index"), ep(.page, "ghost"), "reference"),
    };
    try std.testing.expectError(error.UnknownEndpoint, render(gpa, &pages, &edges, .mermaid));
    const bad_relations = [_]graph_mod.Node{
        .{ .index = 0, .id = "index", .source_path = "index.md", .role = .trunk, .semantic_relations = &.{.{ .kind = .{ .value = "supersedes" }, .target = "ghost" }} },
    };
    try std.testing.expectError(error.UnknownEndpoint, render(gpa, &bad_relations, &.{}, .dot));
}

test "hostile titles cannot break either container" {
    const gpa = std.testing.allocator;
    const pages = [_]graph_mod.Node{
        .{
            .index = 0,
            .id = "index",
            .source_path = "index.md",
            .title = "A\"] --> B[\"injected",
            .role = .trunk,
        },
        .{
            .index = 1,
            .id = "other",
            .source_path = "other.md",
            .title = "line\nbreak\r\nand #quot; entity",
            .role = .satellite,
            .parent = "index",
        },
    };
    const edges = [_]pipeline.DependencyEdge{
        link(ep(.page, "other"), ep(.page, "index"), "parent"),
    };
    const mermaid = try render(gpa, &pages, &edges, .mermaid);
    defer gpa.free(mermaid);
    // No raw quote, newline, or `#` entity escape survives from the title.
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "A#quot;] --#62; B[#quot;injected") != null);
    try std.testing.expect(std.mem.indexOf(u8, mermaid, "line break  and #35;quot; entity") != null);

    const dot = try render(gpa, &pages, &edges, .dot);
    defer gpa.free(dot);
    try std.testing.expect(std.mem.indexOf(u8, dot, "label=\"A\\\"] --> B[\\\"injected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dot, "line break  and #quot; entity") != null);
}
