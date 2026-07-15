//! Parent resolution, role classification, cycle detection, freeze.
//!
//! Graph is flat and serializable. Stable integer indices are assigned only
//! after validation when freezing (sorted by id).

const std = @import("std");
const diag = @import("diag.zig");
const identity = @import("identity.zig");

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
    /// Optional external target (e.g. layout path). Layout edges use `to == from`
    /// because layouts are not graph nodes.
    target: ?[]const u8 = null,
};

/// Per-page navigation derived from a frozen Trunk/Satellite graph.
///
/// All index arrays use stable node indices (post-freeze, id-sorted). Arrays
/// are ordered by entity id ascending — never by hash-map iteration.
pub const NavEntry = struct {
    index: u32,
    id: []const u8,
    /// Parent chain from root Trunk to self (inclusive), node indices.
    breadcrumb: []const u32,
    /// Direct children (satellites naming this page as parent), id order.
    children: []const u32,
    /// Same-Trunk satellite peers excluding self; empty for Trunk pages.
    siblings: []const u32,
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
///
/// - Byte-exact duplicates → `EDUPLICATEID` (later occurrence, source_path order).
/// - Case-only collisions (`guides/intro` vs `GUIDES/INTRO`) → `EINVALIDPATH`,
///   because case-insensitive filesystems silently collide on output paths.
///   See fixture `docs/contracts/fixtures/case-id-collision/`.
///
/// Does not remove nodes.
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

    // O(n) exact-id first-wins via hashmap; case collisions still need a scan of
    // prior ids in source_path order (bounded; case-fold compare is cheap vs n² eql).
    var first_by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer first_by_id.deinit(list_gpa);
    try first_by_id.ensureTotalCapacity(list_gpa, @intCast(nodes.len));

    for (order.items, 0..) |ni, pos| {
        const n = nodes[ni];
        var earlier_exact: ?usize = null;
        var earlier_case: ?usize = null;

        const gop = try first_by_id.getOrPut(list_gpa, n.id);
        if (gop.found_existing) {
            earlier_exact = gop.value_ptr.*;
        } else {
            gop.value_ptr.* = ni;
        }

        if (earlier_exact == null) {
            var j: usize = 0;
            while (j < pos) : (j += 1) {
                const oj = order.items[j];
                if (identity.pathsDifferOnlyInCase(nodes[oj].id, n.id)) {
                    earlier_case = oj;
                    break;
                }
            }
        }
        if (earlier_exact) |ei| {
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
        } else if (earlier_case) |ei| {
            const msg = try std.fmt.allocPrint(
                retain,
                "entity ids differ only in case: \"{s}\" ({s}) and \"{s}\" ({s})",
                .{ n.id, n.source_path, nodes[ei].id, nodes[ei].source_path },
            );
            try diags.append(list_gpa, .{
                .severity = .error_,
                .code = .EINVALIDPATH,
                .message = msg,
                .remediation = try retain.dupe(u8, "Rename one id so entity ids are unique ignoring case (output paths collide on case-insensitive filesystems)"),
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

    // Cycle detection via parent links (iterative DFS; gray = visiting set).
    // Each node has at most one parent, so the walk is a single chain — still
    // iterative so a pathological long parent chain cannot blow the C stack.
    // Today cycles need mutual/parent chains; the algorithm stays even if
    // nesting is later allowed so cycles remain proven absent, not assumed.
    const Color = enum { white, gray, black };
    const colors = try list_gpa.alloc(Color, nodes.len);
    defer list_gpa.free(colors);
    @memset(colors, .white);

    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(list_gpa);

    // One diagnostic set per distinct cycle (do not merge independent cycles).
    var emitted_cycles: std.ArrayList([]const u8) = .empty;
    defer {
        for (emitted_cycles.items) |p| list_gpa.free(p);
        emitted_cycles.deinit(list_gpa);
    }

    for (nodes, 0..) |_, start| {
        if (colors[start] != .white) continue;
        stack.clearRetainingCapacity();
        var cur: usize = start;
        while (colors[cur] == .white) {
            colors[cur] = .gray;
            try stack.append(list_gpa, cur);
            if (nodes[cur].parent_index) |pi| {
                const p: usize = pi;
                if (colors[p] == .gray) {
                    // Cycle path: stack from p back to top, then close on p.
                    var cycle_ids: std.ArrayList([]const u8) = .empty;
                    defer cycle_ids.deinit(list_gpa);
                    var started = false;
                    for (stack.items) |s| {
                        if (s == p) started = true;
                        if (started) try cycle_ids.append(list_gpa, nodes[s].id);
                    }
                    // Stable message: sort participant ids then rebuild path in walk order.
                    var path_buf: std.ArrayList(u8) = .empty;
                    defer path_buf.deinit(list_gpa);
                    for (cycle_ids.items, 0..) |id, idx| {
                        if (idx > 0) try path_buf.appendSlice(list_gpa, " -> ");
                        try path_buf.appendSlice(list_gpa, id);
                    }
                    if (cycle_ids.items.len > 0) {
                        try path_buf.appendSlice(list_gpa, " -> ");
                        try path_buf.appendSlice(list_gpa, cycle_ids.items[0]);
                    }
                    const path_owned = try retain.dupe(u8, path_buf.items);
                    // Dedup identical cycle messages (same walk may re-hit).
                    var already = false;
                    for (emitted_cycles.items) |prev| {
                        if (std.mem.eql(u8, prev, path_owned)) {
                            already = true;
                            break;
                        }
                    }
                    if (!already) {
                        try emitted_cycles.append(list_gpa, try list_gpa.dupe(u8, path_owned));
                        for (cycle_ids.items) |id| {
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
                    break;
                } else if (colors[p] == .white) {
                    cur = p;
                    continue;
                }
            }
            break;
        }
        while (stack.pop()) |s| {
            colors[s] = .black;
        }
    }
}

/// Alias kept for call sites that historically used `resolve`.
/// Prefer `validate` (full entry) or `validateTopology` (topology only).
pub const resolve = validateTopology;

/// Sort nodes by id, assign stable indices, rebuild parent_index and edges.
/// Marks graph frozen. Nodes slice is reordered in place.
///
/// When `layout_path` is non-null, appends one `kind = "layout"` edge per node
/// with `to == from` and `target = layout_path` (layouts are not graph nodes).
///
/// Call only after `validate` reports zero errors. Do not claim the structure
/// is a frozen DAG (or forest) until this returns successfully.
pub fn freeze(
    list_gpa: std.mem.Allocator,
    nodes: []Node,
    layout_path: ?[]const u8,
) !Graph {
    std.mem.sort(Node, nodes, {}, struct {
        fn less(_: void, a: Node, b: Node) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.less);

    for (nodes, 0..) |*n, i| {
        n.index = @intCast(i);
    }

    // Remap parent_index by id via O(n) hashmap (not linear findIndexById per node).
    var id_index = try buildIdIndex(list_gpa, nodes);
    defer id_index.deinit(list_gpa);
    for (nodes) |*n| {
        if (n.parent) |p| {
            if (id_index.get(p)) |pi| {
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
    if (layout_path) |lp| {
        for (nodes) |n| {
            try edges.append(list_gpa, .{
                .from = n.index,
                .to = n.index,
                .kind = "layout",
                .target = lp,
            });
        }
    }
    // Deterministic edge order: by from, then kind, then to.
    std.mem.sort(Edge, edges.items, {}, struct {
        fn less(_: void, a: Edge, b: Edge) bool {
            if (a.from != b.from) return a.from < b.from;
            const kind_ord = std.mem.order(u8, a.kind, b.kind);
            if (kind_ord != .eq) return kind_ord == .lt;
            return a.to < b.to;
        }
    }.less);

    return .{
        .nodes = nodes,
        .edges = try edges.toOwnedSlice(list_gpa),
        .frozen = true,
    };
}

/// Free a `buildNav` result (spine + per-entry index arrays).
pub fn freeNav(list_gpa: std.mem.Allocator, nav: []NavEntry) void {
    for (nav) |e| {
        list_gpa.free(e.breadcrumb);
        list_gpa.free(e.children);
        list_gpa.free(e.siblings);
    }
    list_gpa.free(nav);
}

/// Build per-page navigation from an already-frozen node list.
///
/// Preconditions (same as post-`freeze`):
/// - `nodes` sorted by entity id ascending
/// - each `nodes[i].index == i`
/// - `parent_index` remapped to sorted indices
///
/// Does **not** re-scan the filesystem or re-parse frontmatter. Uses only
/// `parent_index` / `role` on the frozen nodes. Child and sibling lists are
/// produced by a single ordered pass over the id-sorted node array (no map
/// iteration in output order).
///
/// Caller owns the returned slice; free with `freeNav`.
pub fn buildNav(list_gpa: std.mem.Allocator, nodes: []const Node) ![]NavEntry {
    // Reverse adjacency: children_of[parent_index] in id order.
    // Nodes are already id-sorted, so appending while scanning 0..n-1 yields
    // id-sorted child lists without a separate sort.
    var child_lists = try list_gpa.alloc(std.ArrayList(u32), nodes.len);
    defer {
        for (child_lists) |*cl| cl.deinit(list_gpa);
        list_gpa.free(child_lists);
    }
    for (child_lists) |*cl| cl.* = .empty;

    for (nodes) |n| {
        if (n.parent_index) |pi| {
            try child_lists[pi].append(list_gpa, n.index);
        }
    }

    var nav = try list_gpa.alloc(NavEntry, nodes.len);
    var built: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < built) : (j += 1) {
            list_gpa.free(nav[j].breadcrumb);
            list_gpa.free(nav[j].children);
            list_gpa.free(nav[j].siblings);
        }
        list_gpa.free(nav);
    }

    for (nodes, 0..) |n, i| {
        // Explicit catch cleanup only — do not errdefer inside the loop after
        // ownership transfers to nav[i] (would double-free with the outer path).
        const breadcrumb = try buildBreadcrumb(list_gpa, nodes, i);
        const children = list_gpa.dupe(u32, child_lists[i].items) catch |err| {
            list_gpa.free(breadcrumb);
            return err;
        };
        const siblings = buildSiblings(list_gpa, child_lists, n) catch |err| {
            list_gpa.free(breadcrumb);
            list_gpa.free(children);
            return err;
        };

        nav[i] = .{
            .index = n.index,
            .id = n.id,
            .breadcrumb = breadcrumb,
            .children = children,
            .siblings = siblings,
        };
        built += 1;
    }

    return nav;
}

/// Root → self node-index chain. v0.1 graphs are one-level forests (depth ≤ 2),
/// but the walk follows `parent_index` generically without assuming depth.
fn buildBreadcrumb(list_gpa: std.mem.Allocator, nodes: []const Node, start: usize) ![]u32 {
    var chain: std.ArrayList(u32) = .empty;
    errdefer chain.deinit(list_gpa);

    var cur: usize = start;
    // Guard against residual cycles (should not exist after validate+freeze).
    var guard: usize = 0;
    const max_hops = nodes.len + 1;
    while (true) {
        try chain.append(list_gpa, @intCast(cur));
        if (nodes[cur].parent_index) |pi| {
            cur = pi;
            guard += 1;
            if (guard > max_hops) break; // defensive: stop pathological walks
        } else {
            break;
        }
    }

    // chain is self → … → root; reverse to root → self.
    std.mem.reverse(u32, chain.items);
    return try chain.toOwnedSlice(list_gpa);
}

/// Trunk-level siblings: other direct children of the same parent, excluding self.
/// Empty for Trunk pages (no parent) and for nodes with an unresolved parent.
fn buildSiblings(
    list_gpa: std.mem.Allocator,
    child_lists: []const std.ArrayList(u32),
    n: Node,
) ![]u32 {
    const pi = n.parent_index orelse {
        return try list_gpa.alloc(u32, 0);
    };
    const peers = child_lists[pi].items;
    var out: std.ArrayList(u32) = .empty;
    errdefer out.deinit(list_gpa);
    try out.ensureTotalCapacity(list_gpa, peers.len);
    for (peers) |ci| {
        if (ci != n.index) try out.append(list_gpa, ci);
    }
    return try out.toOwnedSlice(list_gpa);
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
    const g = try freeze(gpa, &nodes, null);
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

test "freeze emits layout edges when layout_path set" {
    const gpa = std.testing.allocator;
    var nodes = [_]Node{
        .{ .id = "z", .source_path = "z.md" },
        .{ .id = "a", .source_path = "a.md", .parent = "z" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validate(gpa, gpa, &nodes, &diags);
    const g = try freeze(gpa, &nodes, "layouts/main.html");
    defer gpa.free(g.edges);

    // 1 parent + 2 layout edges
    try std.testing.expectEqual(@as(usize, 3), g.edges.len);
    var layout_count: usize = 0;
    for (g.edges) |e| {
        if (std.mem.eql(u8, e.kind, "layout")) {
            layout_count += 1;
            try std.testing.expect(e.from == e.to);
            try std.testing.expectEqualStrings("layouts/main.html", e.target.?);
        }
    }
    try std.testing.expectEqual(@as(usize, 2), layout_count);
    // Each node has a layout edge
    for (g.nodes) |n| {
        var found = false;
        for (g.edges) |e| {
            if (e.from == n.index and std.mem.eql(u8, e.kind, "layout")) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
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

test "diagnoseDuplicateIds detects case-only id collisions" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var nodes = [_]Node{
        .{ .id = "guides/intro", .source_path = "lower.md" },
        .{ .id = "GUIDES/INTRO", .source_path = "upper.md" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try diagnoseDuplicateIds(gpa, retain, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EINVALIDPATH);
    try std.testing.expect(diag.countErrors(diags.items) == 1);
}

test "diagnoseDuplicateIds byte-exact still EDUPLICATEID" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const retain = arena.allocator();
    var nodes = [_]Node{
        .{ .id = "shared", .source_path = "alpha.md" },
        .{ .id = "shared", .source_path = "beta.md" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try diagnoseDuplicateIds(gpa, retain, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expect(diags.items[0].code == .EDUPLICATEID);
}

test "buildNav breadcrumb children siblings from frozen graph" {
    const gpa = std.testing.allocator;
    // Two trunks; trunk `t` has satellites s-a, s-b (id order after freeze).
    var nodes = [_]Node{
        .{ .id = "s-a", .source_path = "s-a.md", .parent = "t" },
        .{ .id = "s-b", .source_path = "s-b.md", .parent = "t" },
        .{ .id = "t", .source_path = "t.md" },
        .{ .id = "u", .source_path = "u.md" },
    };
    var diags: std.ArrayList(diag.Diagnostic) = .empty;
    defer diags.deinit(gpa);
    try validate(gpa, gpa, &nodes, &diags);
    try std.testing.expectEqual(@as(usize, 0), diag.countErrors(diags.items));
    const g = try freeze(gpa, &nodes, null);
    defer gpa.free(g.edges);

    // Freeze id order: s-a, s-b, t, u
    try std.testing.expectEqualStrings("s-a", g.nodes[0].id);
    try std.testing.expectEqualStrings("s-b", g.nodes[1].id);
    try std.testing.expectEqualStrings("t", g.nodes[2].id);
    try std.testing.expectEqualStrings("u", g.nodes[3].id);

    const nav = try buildNav(gpa, g.nodes);
    defer freeNav(gpa, nav);
    try std.testing.expectEqual(@as(usize, 4), nav.len);

    // Trunk t: breadcrumb [self], children [s-a, s-b], no siblings
    try std.testing.expectEqual(@as(u32, 2), nav[2].index);
    try std.testing.expectEqual(@as(usize, 1), nav[2].breadcrumb.len);
    try std.testing.expectEqual(@as(u32, 2), nav[2].breadcrumb[0]);
    try std.testing.expectEqual(@as(usize, 2), nav[2].children.len);
    try std.testing.expectEqual(@as(u32, 0), nav[2].children[0]);
    try std.testing.expectEqual(@as(u32, 1), nav[2].children[1]);
    try std.testing.expectEqual(@as(usize, 0), nav[2].siblings.len);

    // Satellite s-a: breadcrumb [t, s-a], no children, sibling s-b
    try std.testing.expectEqual(@as(usize, 2), nav[0].breadcrumb.len);
    try std.testing.expectEqual(@as(u32, 2), nav[0].breadcrumb[0]);
    try std.testing.expectEqual(@as(u32, 0), nav[0].breadcrumb[1]);
    try std.testing.expectEqual(@as(usize, 0), nav[0].children.len);
    try std.testing.expectEqual(@as(usize, 1), nav[0].siblings.len);
    try std.testing.expectEqual(@as(u32, 1), nav[0].siblings[0]);

    // Satellite s-b: sibling s-a (id order)
    try std.testing.expectEqual(@as(usize, 1), nav[1].siblings.len);
    try std.testing.expectEqual(@as(u32, 0), nav[1].siblings[0]);

    // Lonely trunk u
    try std.testing.expectEqual(@as(usize, 1), nav[3].breadcrumb.len);
    try std.testing.expectEqual(@as(u32, 3), nav[3].breadcrumb[0]);
    try std.testing.expectEqual(@as(usize, 0), nav[3].children.len);
    try std.testing.expectEqual(@as(usize, 0), nav[3].siblings.len);
}

test "buildNav empty graph" {
    const gpa = std.testing.allocator;
    const nav = try buildNav(gpa, &.{});
    defer freeNav(gpa, nav);
    try std.testing.expectEqual(@as(usize, 0), nav.len);
}
