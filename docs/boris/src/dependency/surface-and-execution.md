---
title: "`src/dependency.zig` surface and execution"
id: docs/boris/src/dependency/surface-and-execution
parent: docs/boris/src/dependency
status: draft
tags: [boris, zig, source-reference, surface, dependency]
---

# `src/dependency.zig` surface and execution

## Data model

### `DependencyKind`

An enum with five variants and a `name()` method:

| Variant | String representation | Semantic meaning |
| --- | --- | --- |
| `parent` | `"parent"` | Hierarchical parent edge in the Trunk/Satellite graph |
| `layout` | `"layout"` | Layout template dependency |
| `include` | `"include"` | `&#123;&#123;include&#125;&#125;` transclusion edge |
| `reference` | `"reference"` | `&#91;&#91;wikilink&#93;&#93;` or explicit reference edge |
| `asset` | `"asset"` | Page asset dependency (image, file, etc.) |

The `name()` method returns a string literal for each variant. This output is used directly by `renderJson` to write the `"kind"` field. There is no inverse (string → enum) function in this file.

The integer order of the enum is used as a sort key in `compareDependency` when two `Dependency` values share the same `path`. The order is determined by declaration order in the source: `parent=0, layout=1, include=2, reference=3, asset=4`. This ordering is not documented as a contract in the file itself.

### `Dependency`

```

pub const Dependency = struct {
path: []const u8,
kind: DependencyKind,
};

```

A flat struct. Both fields are value types or slices; the struct itself carries no allocator. Ownership of `path` is not specified within this struct — the caller is responsible for ensuring the slice remains valid for the lifetime of any `DependencyIndex` that holds it.

### Comparison functions

Two free functions are exported:

- `compareDependency(_: void, a: Dependency, b: Dependency) bool` — primary sort by `path` (lexicographic), secondary sort by `@intFromEnum(kind)`. Used with `std.mem.sort` in `renderJson`.
- `compareStrings(_: void, a: []const u8, b: []const u8) bool` — simple lexicographic string comparator. Used to sort hash-map key slices before iteration in `renderJson`.

Both are compatible with `std.mem.sort`'s comparator signature. Neither function is a strict weak ordering validator; the code does not defensively assert transitivity or irreflexivity, but the underlying `std.mem.order` is correct for these purposes.

***

## `DependencyIndex`

### Fields

| Field | Type | Role |
| --- | --- | --- |
| `allocator` | `std.mem.Allocator` | Retained for all internal allocation |
| `forward` | `std.StringHashMapUnmanaged(std.ArrayList(Dependency))` | Source path → list of outgoing dependencies |
| `reverse` | `std.StringHashMapUnmanaged(std.ArrayList(Dependency))` | Target path → list of incoming dependencies (with source path in `Dependency.path`) |

### Lifetime and initialization

`DependencyIndex.init(allocator)` records the allocator and returns zero-initialized hash maps. No allocation occurs at init time. The caller owns the returned value and must call `deinit` when done.

`DependencyIndex.deinit(self: *DependencyIndex)` iterates both hash maps and calls `list.deinit(self.allocator)` on each value, then calls `self.forward.deinit(self.allocator)` and `self.reverse.deinit(self.allocator)`. This correctly disposes of all internally allocated memory, assuming the allocator passed at init time is still live. The hash map keys (string slices) are **not** freed here — they are owned by the caller and must outlive the index. This is a caller contract, not a structurally enforced invariant.

### `addDependency`

```

pub fn addDependency(
self: *DependencyIndex,
source: []const u8,
target: []const u8,
kind: DependencyKind,
) !void

```

Inserts one typed directed edge `(source → target, kind)` into both the `forward` and `reverse` maps.

**Forward map entry:** Uses `getOrPut` to obtain or create the `ArrayList(Dependency)` for `source`. Initializes to `.empty` on first use. Scans the existing list linearly for an exact `(path == target, kind == kind)` match before appending. If a duplicate is found, the insertion is skipped silently.

**Reverse map entry:** Mirrors the forward logic. Uses `target` as the map key. Stores a `Dependency{ .path = source, .kind = kind }` in the reverse list, again with a linear deduplication scan.

**Error behavior:** Any allocation failure propagates as an error return. There is no rollback of a partially completed `addDependency` call — if the forward insertion succeeds but the reverse allocation fails, the forward entry is left in place. This is a potential partial-update hazard for callers that do not abort the entire index on error.

**Complexity:** Deduplication uses O(n) linear scans per call, where n is the current length of the per-key list. For typical documentation sites with bounded dependency fan-out, this is acceptable. For pathological inputs with very high fan-out from a single source, performance degrades. The code contains no assertion or limit on list length.

**Key ownership:** `source` and `target` slice references are stored directly (as hash-map keys and as `Dependency.path` values). The index does not copy them. Caller must ensure these slices remain valid for the lifetime of the index.

### `renderJson`

```

pub fn renderJson(self: *DependencyIndex, gpa: std.mem.Allocator) ![]u8

```

Allocates and returns a caller-owned UTF-8 JSON byte slice. The caller is responsible for freeing it with `gpa.free(json)`.

Note that `renderJson` accepts a **separate** allocator argument (`gpa`) rather than using `self.allocator`. This allows the caller to use a different allocator for the output buffer than was used to construct the index. All internal temporary allocations in `renderJson` (key lists `fw_keys`, `rv_keys`) also use `gpa`. The `errdefer buf.deinit(gpa)` guard frees the output buffer on any error return.

**Sorting strategy:**
1. All forward source keys are collected into a temporary `ArrayList([]const u8)`, sorted with `compareStrings`, then iterated in that order.
2. Within each source's dependency list, `std.mem.sort` with `compareDependency` is called in-place on the list's items before serializing. This mutates the stored lists as a side effect of rendering. Repeated calls to `renderJson` will still produce identical output because sort is idempotent, but callers should be aware that the order of items in the internal lists is not preserved.
3. Reverse keys follow the same pattern.

**JSON structure emitted:**

```json
{
  "schemaVersion": "0.1.0",
  "forward": {
    "<source-path>": [
      { "target": "<target-path>", "kind": "<kind-name>" }
    ]
  },
  "reverse": {
    "<target-path>": [
      { "source": "<source-path>", "kind": "<kind-name>" }
    ]
  }
}
```

The schema version emitted is `"0.1.0"`. This differs from the IR `schemaVersion` of `"0.2.0"` stated in `docs/STATUS.md`. Whether `dependency.zig`'s `renderJson` output is consumed as a standalone artifact or embedded into the main IR manifest is not determined by reading this file alone — the version discrepancy should be investigated in the context of pipeline.zig or the IR contract documents.

**Indentation and escaping:** Uses `json_out.indent` (2-space per level, up to 4 levels deep) and `json_out.writeString` (which calls `json_out.escapeAppend`, handling `"`, `\`, `\n`, `\r`, `\t`, and control characters < 0x20 with `\uXXXX`). Null bytes (0x00) are treated as control characters and emitted as `\u0000`. High bytes (≥ 0x80) pass through unescaped, which is valid for UTF-8 JSON but means the output is not ASCII-safe.

***
