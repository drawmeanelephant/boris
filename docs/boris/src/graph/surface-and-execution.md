---
title: "`src/graph.zig` surface and execution"
id: docs/boris/src/graph/surface-and-execution
parent: docs/boris/src/graph
status: draft
tags: [boris, zig, source-reference, surface, graph, validation]
---

# `src/graph.zig` surface and execution

## Public API surface

### Types

| Type | Description |
| --- | --- |
| `Role` | Enum: `.trunk` (no parent) or `.satellite` (has a resolved parent). |
| `Node` | A single content document in the provisional graph. Holds entity ID, source path, optional title, optional parent ID string, optional resolved `parent_index` (mutable), role, body offset, tags, and semantic relations. `semantic_relations` are carried through but explicitly excluded from build-dependency walks. |
| `Edge` | A directed edge: `from` index → `to` index, `kind` string (`"parent"` or `"layout"`), and optional `target` for layout edges. Layout edges use `to == from` because layouts are not graph nodes. |
| `NavEntry` | Per-page navigation result: stable `index`, entity `id`, `breadcrumb` (root→self chain of node indices), `children` (direct satellite indices, id-sorted), `siblings` (satellite peers excluding self, id-sorted). All index arrays use post-freeze stable indices. |
| `Graph` | The final frozen value: `nodes` slice (sorted by id), `edges` slice (sorted by from/kind/to), `frozen` flag. |

### Functions

| Function | Visibility | Mutates | Description |
| --- | --- | --- | --- |
| `diagnoseDuplicateIds` | `pub` | `nodes` (no mutation), `diags` | Detects byte-exact duplicate IDs (`EDUPLICATEID`) and case-only collisions (`EINVALIDPATH`). Processes nodes in `source_path` order for stable "first wins" reporting. |
| `validate` | `pub` | `nodes` (role/parent_index), `diags` | Normative entry point: calls `diagnoseDuplicateIds` then `validateTopology`. All graph-dependent emitters must use this. |
| `validateTopology` | `pub` | `nodes` (role/parent_index), `diags` | Resolves parent IDs to indices, classifies roles, detects satellite-of-satellite chains, performs iterative DFS cycle detection. |
| `resolve` | `pub` (alias) | — | Public alias for `validateTopology`; retained for historical call sites. |
| `freeze` | `pub` | `nodes` (sorted in place, indices assigned) | Sorts nodes by id, assigns stable indices, remaps `parent_index` by id, builds and sorts the `edges` slice, optionally appends layout edges, marks `frozen = true`. Returns a `Graph`. |
| `buildNav` | `pub` | — (reads frozen nodes) | Constructs `[]NavEntry` from a frozen node list. Builds reverse adjacency in a single pass; produces breadcrumb, children, and siblings for each node. Caller owns result; free with `freeNav`. |
| `freeNav` | `pub` | — | Frees all per-entry index arrays and the spine slice from a `buildNav` result. |
| `buildIdIndex` | private | — | Builds a `StringHashMapUnmanaged(usize)` from node ID to provisional array index. First-wins for duplicates; used by `validateTopology` and `freeze`. |
| `findIndexById` | private | — | Linear scan for a node by ID; used by cycle detection to locate diagnostics targets. O(n) per call; only invoked inside the cycle-reporting path. |
| `buildBreadcrumb` | private | — | Follows `parent_index` from a node to the root, reverses the resulting chain. Includes a defensive `guard` counter capped at `nodes.len + 1` to abort on residual cycles that should not exist post-freeze. |
| `buildSiblings` | private | — | Returns all children of a node's parent, excluding the node itself, from the pre-built reverse-adjacency lists. Empty for trunks. |

***

## Allocator contract

`src/graph.zig` functions accept two allocators by convention:

- **`list_gpa`**: A general-purpose allocator (often the testing allocator or a non-arena GPA) used for all transient bookkeeping: sort buffers, hash maps, `ArrayList` spines, DFS color arrays, and cycle-dedup lists. All such memory is freed before the function returns (via `defer` or `errdefer`).
- **`retain`**: A long-lived allocator (typically a build-session arena) used exclusively for strings embedded in `diag.Diagnostic` values. These strings must outlive the current call since diagnostics are aggregated across multiple validation passes and reported after the fact.

The caller is responsible for freeing `g.edges` from `freeze` (the nodes slice is the caller's — it is sorted in place, not re-allocated). `buildNav` returns caller-owned memory; `freeNav` is the matching destructor. There is no destructor for `Graph.nodes` because that slice is the caller's input array.

No function in this module claims to be allocation-free. Error returns propagate allocator failures (`error.OutOfMemory`) through all public entry points.

***

## Validation algorithm detail

### `diagnoseDuplicateIds`

1. Builds a sort permutation of node indices ordered by `source_path` (stable "first wins" = alphabetically earlier file keeps its ID).
2. Walks nodes in that order. For each node, attempts `getOrPut` in a `StringHashMapUnmanaged`. If the ID already exists: emits `EDUPLICATEID`.
3. If the ID was not an exact duplicate: scans all previously processed nodes (in source-path order, bounded by `pos`) comparing via `identity.pathsDifferOnlyInCase`. If a case-only collision is found: emits `EINVALIDPATH`. This inner scan is O(n²) worst-case but bounded by the comment as "cheap vs n² eql" given the ASCII case-fold.
4. Does not remove nodes; does not abort early. All duplicates are diagnosed.

### `validateTopology`

1. Builds `by_id: StringHashMapUnmanaged(usize)` (first-wins for duplicate IDs — duplicates are already diagnosed before this runs in the `validate` entry point).
2. **Self-parent check**: if `parent == id`, emits `EPARENTSELF`, sets role to `.satellite`, clears `parent_index`, and `continue`s.
3. **Missing-parent check**: if `parent` is present but not in `by_id`, emits `EPARENTMISSING`, sets role to `.satellite`, clears `parent_index`.
4. **Satellite-of-satellite pass**: iterates nodes; if `parent_index` is set and `nodes[parent_index].parent != null`, emits `EPARENTNOTTRUNK`. This is a hard error for v0.1.
5. **Cycle detection**: Allocates a `Color` array (`white`/`gray`/`black`). Performs an iterative DFS (not recursive, to avoid stack overflow on long parent chains). When a gray node is reached again, collects the cycle path from the stack, deduplicates against `emitted_cycles`, and emits one `EPARENTCYCLE` diagnostic per cycle participant.

**Important observation**: the satellite-of-satellite check uses `parent.parent != null` as its proxy, not `parent.role == .satellite`. This is structurally correct given that `.role` is set in pass 2, which runs before the satellite-of-satellite pass. However, it means the check depends on the raw `parent` field string being non-null rather than the resolved role — a node whose parent was set to `.satellite` due to `EPARENTSELF` will have `parent != null` and would trigger a spurious `EPARENTNOTTRUNK` if another node named it as a parent. This edge case is not covered by an existing test.

### `freeze`

1. Sorts `nodes` in place by entity ID (byte-order ascending, `std.mem.order`).
2. Assigns `node.index = i` for each node in sorted order.
3. Rebuilds `parent_index` for every node by looking up `parent` in a freshly built `by_id` map over the now-sorted array.
4. Builds the edges slice: one `"parent"` edge per node with a resolved `parent_index`, then (if `layout_path` is non-null) one `"layout"` edge per node with `to == from` and `target = layout_path`.
5. Sorts edges deterministically: primary by `from`, secondary by `kind` (byte order), tertiary by `to`.
6. Sets `frozen = true` and returns the `Graph`.

***
