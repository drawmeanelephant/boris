//! Parent resolution, role classification, cycle detection, freeze.
//!
//! Graph is flat and serializable. Stable integer indices are assigned only
//! after validation when freezing (sorted by id).

const std = @import("std");
const diag = @import("diag.zig");

pub const Role = enum {
    trunk,
    satellite,

    pub fn name(self: Role) []const u8 {
        return @tagName(self);
    }
};

pub const Node = struct {
    /// Stable index after freeze (0..n-1), sorted by id.
    index: u32 = 0,
    id: []const u8,
    source_path: []const u8,
    title: ?[]const u8 = null,
    parent: ?[]const u8 = null,
    parent_index: ?u32 = null,
    status: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    role: Role = .trunk,
    body_offset: usize = 0,
};

pub const Edge = struct {
    from: u32,
    to: u32,
    kind: []const u8 = "parent",
};

pub const Graph = struct {
    nodes: []Node = &.{},
    edges: []Edge = &.{},
    frozen: bool = false,
};

fn findIndexById(nodes: []const Node, id: []const u8) ?usize {
    for (nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.id, id)) return i;
    }
    return null;
}

/// Build id → provisional index map (O(n)). Used by resolve for O(1) parent lookups.
fn buildIdIndex(list_gpa: std.mem.Allocator, nodes: []const Node) !std.StringHashMapUnmanaged(usize) {
    var map: std.StringHashMapUnmanaged(usize) = .empty;
    errdefer map.deinit(list_gpa);
    try map.ensureTotalCapacity(list_gpa, @intCast(nodes.len));
    for (nodes, 0..) |n, i| {
        // First wins for lookup; duplicates are diagnosed separately.
        const gop = try map.getOrPut(list_gpa, n.id);
        if (!gop.found_existing) gop.value_ptr.* = i;
    }
    return map;
}

/// Detect duplicate ids among provisional nodes (by id string).
/// Does not remove nodes; records EDUPLICATEID on later occurrences (sorted by source_path first).
pub fn diagnoseDuplicateIds(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    nodes: []Node,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    // Work in source_path order for stable "first wins" reporting.
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(list_gpa);
    try order.ensureTotalCapacity(list_gpa, nodes.len);
    for (nodes, 0..) |_, i| try order.append(list_gpa, i);
    std.mem.sort(usize, order.items, nodes, struct {
        fn less(ns: []const Node, a: usize, b: usize) bool {
            return std.mem.order(u8, ns[a].source_path, ns[b].source_path) == .lt;
        }
    }.less);

    for (order.items, 0..) |ni, pos| {
        const n = nodes[ni];
        var earlier: ?usize = null;
        var j: usize = 0;
        while (j < pos) : (j += 1) {
            const oj = order.items[j];
            if (std.mem.eql(u8, nodes[oj].id, n.id)) {
                earlier = oj;
                break;
            }
        }
        if (earlier) |ei| {
            const msg = try std.fmt.allocPrint(
                retain,
                "duplicate id \"{s}\" (also {s})",
                .{ n.id, nodes[ei].source_path },
            );
            try diags.append(list_gpa, .{
                .severity = .error_,
                .code = .EDUPLICATEID,
                .message = msg,
                .remediation = try retain.dupe(u8, "Give each document a unique id (path-derived or id: override)"),
                .source_path = n.source_path,
                .line = 1,
                .column = 1,
                .id = n.id,
            });
        }
    }
}

/// **Single shared graph-validation entry point** for the IR compiler and RAG.
///
/// Both `pipeline.zig` and `rag.zig` must call this before any graph-dependent
/// emit (`graph.json`, RAG `graph/*`, catalog edges). Do not reimplement parent
/// resolution, duplicate-id checks, or cycle detection in those modules.
///
/// Order is normative (contracts `parent-relationships.md`):
///   1. `EDUPLICATEID` — detect duplicate entity ids first
///   2. Topology — self / missing / not-trunk / cycles (`validateTopology`)
///
/// Aggregates all diagnostics (does not abort early — callers check
/// `diag.countErrors`). Mutates nodes' `role` / `parent_index`.
pub fn validate(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    nodes: []Node,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    try diagnoseDuplicateIds(list_gpa, retain, nodes, diags);
    try validateTopology(list_gpa, retain, nodes, diags);
}

/// Parent resolution, role classification, and cycle detection.
///
/// Prefer `validate` at product call sites so duplicate ids are never skipped.
/// This function remains public for focused unit tests of topology alone.
///
/// Mutates nodes' `role` / `parent_index`. Aggregates all diagnostics (does not
/// abort early — callers check `diag.countErrors`).
///
/// Checks (in order):
///   1. `EPARENTSELF` — parent equals own id
///   2. `EPARENTMISSING` — parent id not in the page set
///   3. `EPARENTNOTTRUNK` — parent is itself a satellite (hard error)
///   4. `EPARENTCYCLE` — DFS with visiting (gray) set
///
/// Algorithm (single-threaded):
///   1. Hash map entity id → index (O(n))
///   2. Validate + classify each node (O(n) expected)
///   3. Multi-hop / satellite-of-satellite pass
///   4. DFS gray-set cycle detection (roadmap-safe if nesting is later allowed)
pub fn validateTopology(
    list_gpa: std.mem.Allocator,
    retain: std.mem.Allocator,
    nodes: []Node,
    diags: *std.ArrayList(diag.Diagnostic),
) !void {
    var by_id = try buildIdIndex(list_gpa, nodes);
    defer by_id.deinit(list_gpa);

    // Pass 2: classify + self + missing (parent_index = provisional array index).
    for (nodes) |*n| {
        if (n.parent) |p| {
            if (std.mem.eql(u8, p, n.id)) {
                try diags.append(list_gpa, .{
                    .severity = .error_,
                    .code = .EPARENTSELF,
                    .message = try std.fmt.allocPrint(retain, "parent \"{s}\" refers to this document", .{p}),
                    .remediation = try retain.dupe(u8, "Remove parent or point it at a different document id"),
                    .source_path = n.source_path,
                    .line = 1,
                    .column = 1,
                    .id = n.id,
                });
                n.role = .satellite;
                n.parent_index = null;
                continue;
            }
            if (by_id.get(p)) |pi| {
                n.parent_index = @intCast(pi);
                n.role = .satellite;
            } else {
                try diags.append(list_gpa, .{
                    .severity = .error_,
                    .code = .EPARENTMISSING,
                    .message = try std.fmt.allocPrint(retain, "parent \"{s}\" does not exist", .{p}),
                    .remediation = try retain.dupe(u8, "Create the parent document or fix the parent id"),
                    .source_path = n.source_path,
                    .line = 1,
                    .column = 1,
                    .id = n.id,
                });
                n.role = .satellite;
                n.parent_index = null;
            }
        } else {
            n.role = .trunk;
            n.parent_index = null;
        }
    }

    // Satellite-of-satellite: parent exists but is itself a satellite.
    // v0.1 model is one-level only; multi-hop has no defined semantics — hard fail.
    for (nodes) |n| {
        if (n.parent_index) |pi| {
            const parent = nodes[pi];
            if (parent.parent != null) {
                try diags.append(list_gpa, .{
                    .severity = .error_,
                    .code = .EPARENTNOTTRUNK,
                    .message = try std.fmt.allocPrint(
                        retain,
                        "parent \"{s}\" is a satellite (multi-hop parent chains are unsupported in v0.1)",
                        .{parent.id},
                    ),
                    .remediation = try retain.dupe(u8, "Point parent at a trunk page (no parent of its own)"),
                    .source_path = n.source_path,
                    .line = 1,
                    .column = 1,
                    .id = n.id,
                });
            }
        }
    }

    // Cycle detection via parent links (DFS gray = visiting set).
    // Today cycles need mutual/parent chains; the algorithm stays even if
    // nesting is later allowed so cycles remain proven absent, not assumed.
    const Color = enum { white, gray, black };
    const colors = try list_gpa.alloc(Color, nodes.len);
    defer list_gpa.free(colors);
    @memset(colors, .white);

    var cycle_nodes: std.ArrayList(usize) = .empty;
    defer cycle_nodes.deinit(list_gpa);

    const Dfs = struct {
        fn visit(
            idx: usize,
            ns: []const Node,
            cols: []Color,
            stack: *std.ArrayList(usize),
            gpa: std.mem.Allocator,
            out_cycle: *std.ArrayList(usize),
        ) !void {
            cols[idx] = .gray;
            try stack.append(gpa, idx);
            if (ns[idx].parent_index) |pi| {
                const p: usize = pi;
                if (cols[p] == .gray) {
                    // Cycle: from p along stack back to p.
                    var started = false;
                    for (stack.items) |s| {
                        if (s == p) started = true;
                        if (started) try out_cycle.append(gpa, s);
                    }
                } else if (cols[p] == .white) {
                    try visit(p, ns, cols, stack, gpa, out_cycle);
                }
            }
            _ = stack.pop();
            cols[idx] = .black;
        }
    };

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(list_gpa);

    for (nodes, 0..) |_, i| {
        if (colors[i] == .white) {
            try Dfs.visit(i, nodes, colors, &stack, list_gpa, &cycle_nodes);
        }
    }

    if (cycle_nodes.items.len > 0) {
        // Unique + sort by id for stable message.
        std.mem.sort(usize, cycle_nodes.items, nodes, struct {
            fn less(ns: []const Node, a: usize, b: usize) bool {
                return std.mem.order(u8, ns[a].id, ns[b].id) == .lt;
            }
        }.less);

        var path_buf: std.ArrayList(u8) = .empty;
        defer path_buf.deinit(list_gpa);
        var seen: std.ArrayList([]const u8) = .empty;
        defer seen.deinit(list_gpa);

        for (cycle_nodes.items) |ci| {
            const id = nodes[ci].id;
            var already = false;
            for (seen.items) |s| {
                if (std.mem.eql(u8, s, id)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try seen.append(list_gpa, id);
            if (path_buf.items.len > 0) try path_buf.appendSlice(list_gpa, " -> ");
            try path_buf.appendSlice(list_gpa, id);
        }
        if (seen.items.len > 0) {
            try path_buf.appendSlice(list_gpa, " -> ");
            try path_buf.appendSlice(list_gpa, seen.items[0]);
        }
        const path_owned = try retain.dupe(u8, path_buf.items);

        for (seen.items) |id| {
            const ni = findIndexById(nodes, id).?;
            try diags.append(list_gpa, .{
                .severity = .error_,
                .code = .EPARENTCYCLE,
                .message = try std.fmt.allocPrint(retain, "parent cycle involving {s}", .{path_owned}),
                .remediation = try retain.dupe(u8, "Break the cycle by changing or removing a parent link"),
                .source_path = nodes[ni].source_path,
                .line = 1,
                .column = 1,
                .id = nodes[ni].id,
            });
        }
    }
}

/// Alias kept for call sites that historically used `resolve`.
/// Prefer `validate` (full entry) or `validateTopology` (topology only).
pub const resolve = validateTopology;

/// Sort nodes by id, assign stable indices, rebuild parent_index and edges.
/// Marks graph frozen. Nodes slice is reordered in place.
///
/// Call only after `validate` reports zero errors. Do not claim the structure
/// is a frozen DAG (or forest) until this returns successfully.
pub fn freeze(
    list_gpa: std.mem.Allocator,
    nodes: []Node,
) !Graph {
    std.mem.sort(Node, nodes, {}, struct {
        fn less(_: void, a: Node, b: Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    for (nodes, 0..) |*n, i| {
        n.index = @intCast(i);
    }

    // Remap parent_index by id lookup after sort.
    for (nodes) |*n| {
        if (n.parent) |p| {
            if (findIndexById(nodes, p)) |pi| {
                n.parent_index = @intCast(pi);
            } else {
                n.parent_index = null;
            }
        } else {
            n.parent_index = null;
        }
    }

    var edges: std.ArrayList(Edge) = .empty;
    for (nodes) |n| {
        if (n.parent_index) |pi| {
            try edges.append(list_gpa, .{
                .from = n.index,
                .to = pi,
                .kind = "parent",
            });
        }
    }
    // Deterministic edge order: by from, then to.
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, a: Edge, b: Edge) bool {
            if (a.from != b.from) return a.from < b.from;
            return a.to < b.to;
        }
    }.less);

    return .{
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(list_gpa),
        .frozen = true,
    };
}

fn expectCodeCount(diags: []const diag.Diagnostic, code: diag.Code, want: usize) !void {
    var n: usize = 0;
    for (diags) |d| {
        if (d.code == code) n += 1;
    }
    try std.testing.expectEqual(want, n);
}

test "validateTopology missing and self" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var nodes = [_]Node{
        .{ .id = "a", .source_path = "a.md", .parent = "missing" },
        .{ .id = "b", .source_path = "b.md", .parent = "b" },
        .{ .id = "c", .source_path = "c.md" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validateTopology(gpa, retain, &nodes, &diags);
    try std.testing.expect(nodes[2].role == .trunk);
    try std.testing.expect(nodes[0].role == .satellite);
    try std.testing.expect(nodes[1].role == .satellite);
    try expectCodeCount(diags.items, .EPARENTMISSING, 1);
    try expectCodeCount(diags.items, .EPARENTSELF, 1);
}

test "validateTopology two-node cycle" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var nodes = [_]Node{
        .{ .id = "a", .source_path = "a.md", .parent = "b" },
        .{ .id = "b", .source_path = "b.md", .parent = "a" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validateTopology(gpa, retain, &nodes, &diags);
    try std.testing.expect(diag.countErrors(diags.items) >= 1);
    try expectCodeCount(diags.items, .EPARENTCYCLE, 2); // one per cycle participant
}

test "validateTopology longer cycle (3 nodes)" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var nodes = [_]Node{
        .{ .id = "a", .source_path = "a.md", .parent = "b" },
        .{ .id = "b", .source_path = "b.md", .parent = "c" },
        .{ .id = "c", .source_path = "c.md", .parent = "a" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validateTopology(gpa, retain, &nodes, &diags);
    try expectCodeCount(diags.items, .EPARENTCYCLE, 3);
    // Message lists ids in stable sorted order.
    var saw_path = false;
    for (diags.items) |d| {
        if (d.code == .EPARENTCYCLE and std.mem.indexOf(u8, d.message, "a -> b -> c -> a") != null) {
            saw_path = true;
        }
    }
    try std.testing.expect(saw_path);
}

test "validate valid trunk and satellite" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    var nodes = [_]Node{
        .{ .id = "guides/intro", .source_path = "guides/intro.md" },
        .{ .id = "guides/intro-tips", .source_path = "guides/intro-tips.md", .parent = "guides/intro" },
        .{ .id = "index", .source_path = "index.md" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validate(gpa, retain, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    try std.testing.expect(nodes[0].role == .trunk);
    try std.testing.expect(nodes[1].role == .satellite);
    try std.testing.expect(nodes[1].parent_index.? == 0);
    try std.testing.expect(nodes[2].role == .trunk);
}

test "validate detects duplicate ids before parent resolution" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    // Later source_path loses; parent of shared is intentionally missing so a
    // topology error would also fire if validation continued without dups —
    // we still expect EDUPLICATEID from the first pass.
    var nodes = [_]Node{
        .{ .id = "shared", .source_path = "alpha.md" },
        .{ .id = "shared", .source_path = "beta.md", .parent = "missing-trunk" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validate(gpa, retain, &nodes, &diags);
    try expectCodeCount(diags.items, .EDUPLICATEID, 1);
    // First-wins map: beta's parent lookup may still report missing.
    try std.testing.expect(diag.countErrors(diags.items) >= 1);
}

test "freeze assigns indices by id order" {
    const gpa = std.testing.allocator;
    var nodes = [_]Node{
        .{ .id = "z", .source_path = "z.md" },
        .{ .id = "a", .source_path = "a.md", .parent = "z" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    // parent_index before freeze uses array positions after validate
    try validate(gpa, gpa, &nodes, &diags);
    const g = try freeze(gpa, &nodes);
    defer gpa.free(g.edges);
    try std.testing.expect(g.frozen);
    try std.testing.expectEqualStrings("a", g.nodes[0].id);
    try std.testing.expectEqualStrings("z", g.nodes[1].id);
    try std.testing.expect(g.nodes[0].index == 0);
    try std.testing.expect(g.nodes[1].index == 1);
    try std.testing.expect(g.nodes[0].parent_index.? == 1);
    try std.testing.expectEqual(@as(usize, 1), g.edges.len);
    try std.testing.expect(g.edges[0].from == 0);
    try std.testing.expect(g.edges[0].to == 1);
}

test "validateTopology satellite-of-satellite is hard error EPARENTNOTTRUNK" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();

    // trunk t ← sat s1 ← sat s2 (two-hop, unsupported)
    var nodes = [_]Node{
        .{ .id = "t", .source_path = "t.md" },
        .{ .id = "s1", .source_path = "s1.md", .parent = "t" },
        .{ .id = "s2", .source_path = "s2.md", .parent = "s1" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validateTopology(gpa, retain, &nodes, &diags);

    var not_trunk: usize = 0;
    for (diags.items) |d| {
        if (d.code == .EPARENTNOTTRUNK) {
            not_trunk += 1;
            try std.testing.expect(d.severity == .error_);
            try std.testing.expect(d.isError());
            try std.testing.expectEqualStrings("s2", d.id);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), not_trunk);
    try std.testing.expectEqual(@as(usize, 1), diag.countErrors(diags.items));
    // Still classifies both as satellites; does not invent multi-hop semantics.
    try std.testing.expect(nodes[1].role == .satellite);
    try std.testing.expect(nodes[2].role == .satellite);
}

test "resolve is alias of validateTopology" {
    // Topology helper remains; product paths use `validate` (dups + topology).
    try std.testing.expect(@TypeOf(resolve) == @TypeOf(validateTopology));
}
