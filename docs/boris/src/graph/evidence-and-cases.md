---
title: "`src/graph.zig` evidence and cases"
id: docs/boris/src/graph/evidence-and-cases
parent: docs/boris/src/graph
status: draft
tags: [boris, zig, source-reference, evidence, graph, validation]
---

# `src/graph.zig` evidence and cases

## Tested declarations and entry points

| Declaration / test | Kind | Purpose | Inputs / setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `validateTopology missing and self` | test | Missing parent and self-parent | Nodes: `a` (parent=`"missing"`), `b` (parent=`"b"`), `c` (no parent) | `c` is trunk; `a`, `b` are satellites; exactly 1 `EPARENTMISSING`, 1 `EPARENTSELF` | `validateTopology` pass 2 |
| `validateTopology two-node cycle` | test | Minimal mutual cycle | Nodes: `a` (parent=`"b"`), `b` (parent=`"a"`) | At least 1 error; exactly 2 `EPARENTCYCLE` diagnostics (one per participant) | DFS cycle detection |
| `validateTopology longer cycle (3 nodes)` | test | Three-node cycle with path string check | Nodes: `a→b`, `b→c`, `c→a` | Exactly 3 `EPARENTCYCLE`; at least one diagnostic message contains the substring `"a -> b -> c -> a"` | Cycle-path dedup and stable ordering |
| `validate valid trunk and satellite` | test | Happy path: one trunk, one satellite, one isolated trunk | `guides/intro` (trunk), `guides/intro-tips` (parent=`guides/intro`), `index` (trunk) | Zero errors; correct roles; `parent_index` of satellite is 0 | Full `validate` entry point |
| `validate detects duplicate ids before parent resolution` | test | `EDUPLICATEID` fires before topology | Two nodes with `id = "shared"`; second has `parent = "missing-trunk"` | At least 1 `EDUPLICATEID`; total errors ≥ 1 | `diagnoseDuplicateIds` ordering in `validate` |
| `freeze assigns indices by id order` | test | Post-freeze index assignment and edge wiring | Nodes: `z` (trunk), `a` (parent=`"z"`); validate then freeze | After freeze: `nodes[^1_0].id == "a"`, `nodes[^1_1].id == "z"`; `a.parent_index == 1`; 1 edge from 0 to 1 | `freeze` sort, index, remap, edge construction |
| `freeze emits layout edges when layout_path set` | test | Layout edges appended per node | Same 2-node setup; `freeze(..., "layouts/main.html")` | 3 edges total (1 parent + 2 layout); each layout edge has `from == to` and `target == "layouts/main.html"` | Layout-edge construction |
| `validateTopology satellite-of-satellite is hard error EPARENTNOTTRUNK` | test | Multi-hop chain: trunk ← s1 ← s2 | 3 nodes: `t`, `s1` (parent=`"t"`), `s2` (parent=`"s1"`) | Exactly 1 `EPARENTNOTTRUNK`; severity `.error_`; `d.id == "s2"`; exactly 1 total error; `s1` and `s2` both `.satellite` | Satellite-of-satellite hard error |
| `resolve is alias of validateTopology` | test | Type identity check | — | `@TypeOf(resolve) == @TypeOf(validateTopology)` | Alias correctness |
| `diagnoseDuplicateIds detects case-only id collisions` | test | Case collision → `EINVALIDPATH` | Nodes: `guides/intro` and `GUIDES/INTRO` | Exactly 1 diagnostic; code is `EINVALIDPATH` | `pathsDifferOnlyInCase` integration |
| `diagnoseDuplicateIds byte-exact still EDUPLICATEID` | test | Exact-match dup → `EDUPLICATEID` | Nodes: two `shared` entries | Exactly 1 diagnostic; code is `EDUPLICATEID` | Exact-match branch |
| `buildNav breadcrumb children siblings from frozen graph` | test | Full navigation derivation | 4 nodes: `s-a`, `s-b` (parent=`"t"`), `t` (trunk), `u` (lonely trunk); validate + freeze + buildNav | `nav[^1_2]` (trunk `t`): breadcrumb `[^1_2]`, children `[0,1]`, no siblings; `nav[^1_0]` (s-a): breadcrumb `[2,0]`, sibling `[^1_1]`; `nav[^1_3]` (u): breadcrumb `[^1_3]`, no children, no siblings | `buildNav`, `buildBreadcrumb`, `buildSiblings`, `freeNav` |
| `buildNav empty graph` | test | Zero-node edge case | Empty node slice | Returns zero-length nav slice without panic | `buildNav` empty input |

***

## Control flow

### `validate` entry point

```text
validate(list_gpa, retain, nodes, diags)
    → diagnoseDuplicateIds(list_gpa, retain, nodes, diags)
        → sort by source_path (permutation array)
        → walk in source_path order
            → StringHashMapUnmanaged getOrPut (exact dup → EDUPLICATEID)
            → linear scan of prior entries (case collision → EINVALIDPATH)
    → validateTopology(list_gpa, retain, nodes, diags)
        → buildIdIndex → StringHashMapUnmanaged id→index
        → pass 2: for each node with parent:
            self-parent? → EPARENTSELF
            in map?      → set parent_index, role=satellite
            else         → EPARENTMISSING
        → satellite-of-satellite pass:
            parent_index set AND nodes[parent_index].parent != null → EPARENTNOTTRUNK
        → cycle detection:
            alloc Color[nodes.len]
            for each white start node:
                iterative walk following parent_index, marking gray
                gray hit → collect stack path → dedup → EPARENTCYCLE × participants
                pop stack → mark black
```


### `freeze` (called after validate reports zero errors)

```text
freeze(list_gpa, nodes, layout_path)
    → std.mem.sort nodes by id in place
    → assign node.index = i
    → buildIdIndex on sorted nodes
    → remap parent_index for each node
    → collect parent edges; optionally append layout edges
    → sort edges (from, kind, to)
    → return Graph{ .nodes, .edges, .frozen=true }
```


### `buildNav` (called on frozen nodes)

```text
buildNav(list_gpa, nodes)
    → alloc child_lists[nodes.len] (reverse adjacency)
    → single pass: for each node with parent_index, append to child_lists[parent_index]
    → for each node i:
        buildBreadcrumb: follow parent_index to root, reverse
        dupe child_lists[i].items → children
        buildSiblings: filter child_lists[parent_index] excluding self
        → nav[i] = NavEntry{...}
    → return nav (caller frees with freeNav)
```


***

## Known constraints and edge cases

**`EPARENTSELF` + satellite-of-satellite interaction (uncertain):** A node whose parent is itself (`EPARENTSELF`) has `parent != null` after the self-parent pass (the `parent` field is unchanged; only `parent_index` is cleared). If a *different* node names the self-referential node as its parent, that second node will get `parent_index` set to the self-referential node's index (assuming the map lookup succeeds), and the satellite-of-satellite pass will see `nodes[parent_index].parent != null`, emitting `EPARENTNOTTRUNK`. Whether this is the intended behavior is not tested.

**`buildBreadcrumb` cycle guard:** The guard uses `nodes.len + 1` as a maximum hop count and `break`s silently without emitting an error if it triggers. This is documented as defensive against "residual cycles" that "should not exist after validate+freeze." The guard provides safety but produces a truncated breadcrumb without any diagnostic. No test verifies the guard fires or its output.

**Cycle dedup relies on string equality of path strings:** The `emitted_cycles` list is compared with `std.mem.eql`. Two structurally equivalent cycles starting from different walk entry points will produce the same path string (the path is constructed relative to the gray-set stack, not the start node), so deduplication should work for the simple cases tested. Multi-cycle graphs with overlapping but distinct cycles are not tested.

**`freeze` does not re-validate:** `freeze` trusts that `validate` was called with zero errors and does not re-check for cycles or satellite-of-satellite violations. The `frozen` flag is set unconditionally.

***
