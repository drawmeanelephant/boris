---
title: "`src/ir_emit.zig` surface and execution"
id: docs/boris/src/ir_emit/surface-and-execution
parent: docs/boris/src/ir_emit
status: draft
tags: [boris, zig, source-reference, surface, ir_emit]
---

# `src/ir_emit.zig` surface and execution

## Input contracts and duck-typed interface

All three public functions accept `result: anytype`. The functions access specific fields on `result` without a formal interface declaration; the required shape is inferred from the field accesses in the source:

**Fields accessed on `result` by all three renderers:**
- `result.pages.items` — slice of page nodes; each item must carry `.index`, `.id`, `.source_path`, `.role.name`, `.parent` (`?[]const u8`), `.title` (`?[]const u8`), `.status` (`?[]const u8`)
- `result.content_root` — `[]const u8`

**Additional fields for `renderGraph`:**
- `result.graph_frozen` — `bool`
- `result.edges.items` — slice of dependency edges; each item must carry `.from` (with `.type.name` and `.value`) and `.to` (same), and `.kind` (`[]const u8`)
- `result.reverse_index.items` — slice of reverse-index entries; each item must carry `.target` (endpoint) and `.incoming_edges` (`[]const u32`)
- Each page must additionally carry `.tags` (`[][]const u8`), `.body_offset` (`usize`), `.parent_index` (`?u32`), `.semantic_relations` (slice with `.kind.name` and `.target` fields)

**Additional fields for `renderBuildReport`:**
- `result.ok` — `bool`
- `result.out_dir` — `[]const u8`
- `result.errorCount()` — method returning `usize`
- `result.diagnostics.items` — slice of diagnostics; each item must carry `.severity.json_name`, `.code.name`, `.message`, `.remediation`, `.source_path` (`[]const u8`, empty-string-as-null), `.line` (`?u32`), `.column` (`?u32`), `.id` (`[]const u8`, empty-string-as-null)

The `VersionInfo` struct is declared in `ir_emit.zig` itself:
```zig
pub const VersionInfo = struct {
    schema_version: []const u8,
    compiler_id: []const u8,
    semantic_schema_version: []const u8,
    semantic_compiler_id: []const u8,
};
```


***

## Public API

### `pub fn renderManifest`

**Signature:** `pub fn renderManifest(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8`

Emits `manifest.json`. The output is a single JSON object with top-level keys in this fixed order: `schemaVersion`, `compiler`, `contentRoot`, `pageCount`, `pages`. The `pages` value is a JSON array where each element is an object with keys `index`, `id`, `sourcePath`, `role`, `parent`, `title`, `status`. Optional fields (`parent`, `title`, `status`) emit `null` when absent. The `pages` array carries only the public-facing metadata subset; it omits `tags`, `bodyOffset`, `parentIndex`, `nav`, `edges`, and `reverseIndex` (those appear in `graph.json`).

**Ownership:** Caller owns the returned `[]u8` and must free it with the supplied `gpa`.

**Error behavior:** Any allocation failure propagates as `error.OutOfMemory`. The `errdefer buf.deinit(gpa)` at the top of the function ensures no partial buffer leaks on failure.

**Schema version selection:** Uses `artifactSchemaVersion(result, versions)`, which returns `versions.semantic_schema_version` if any page has semantic relations, otherwise `versions.schema_version`.

***

### `pub fn renderGraph`

**Signature:** `pub fn renderGraph(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8`

Emits `graph.json`. This is the most complex of the three renderers. Its top-level keys in fixed order are: `schemaVersion`, `frozen`, `nodes`, `edges`, `reverseIndex`, `nav`, and conditionally `relations`.

**Nav derivation:** Calls `graphmod.buildNav(gpa, result.pages.items)` at the top of the function, owning the result under `defer graphmod.freeNav(gpa, nav)`. `buildNav` computes breadcrumb, children, and sibling arrays from the frozen node list using `parent_index` and `role`. The nav is emitted as an array of objects with keys `index`, `id`, `breadcrumb`, `children`, `siblings`; each of `breadcrumb`, `children`, `siblings` is a JSON array of `u32` node indices serialized by the private `writeU32Array` helper.

**Semantic relations section:** When `hasSemanticRelations(result)` is true, a `relations` top-level array is emitted after `nav`. The relations are assembled into a temporary `std.ArrayList(SemanticEdge)`, sorted by `(from, to, kind)` using `std.sort.block`, then serialized. The `SemanticEdge` type is defined inline inside the function body using `@TypeOf(result.edges.items[^1_0].from)` to capture the concrete endpoint type from the caller's struct without a formal type parameter. This is a structural duck-typing pattern; the sort comparator accesses `.type.name` and `.value` fields, which must match the endpoint layout.

**Closing brace selection:** The separator between `nav` and `relations` is conditional: when no relations, `nav` closes the object directly; when relations are present, `nav` is followed by a comma and the `relations` key.

**Ownership:** Caller owns the returned `[]u8`.

***

### `pub fn renderBuildReport`

**Signature:** `pub fn renderBuildReport(gpa: std.mem.Allocator, result: anytype, versions: VersionInfo) ![]u8`

Emits `build-report.json`. Top-level keys in fixed order: `schemaVersion`, `ok`, `contentRoot`, `outDir`, `pageCount`, `errorCount`, `diagnostics`.

The `diagnostics` value is either the JSON literal `[]` (when `result.diagnostics.items.len == 0`) or a full array of diagnostic objects. Each diagnostic object has keys: `severity`, `code`, `message`, `remediation`, `sourcePath`, `line`, `column`, `id`. The `sourcePath` field emits `null` when `d.source_path.len == 0`; `line` and `column` use `jsonout.writeOptionalU32` (emits the integer or `null`); `id` emits `null` when `d.id.len == 0`.

Unlike `manifest.json`, `graph.json`, and `completion.json`, `build-report.json` is written on **both success and failure** paths in `pipeline.publishArtifacts`. On content failure, it is the only artifact published; on success, all four are published atomically via staging.

**Schema version note:** `renderBuildReport` also calls `artifactSchemaVersion(result, versions)`, so the `schemaVersion` field reflects the conditional semantic-relations version even in the failure case where the build report is the sole artifact. This is consistent with the code but arguably surprising: a failed build report where no pages were parsed will always emit the base `"0.2.0"` schema version because no pages exist to carry semantic relations.

***

## Private helpers

| Helper | Purpose |
| :-- | :-- |
| `hasSemanticRelations(result)` | Scans `result.pages.items`; returns `true` if any page has `semantic_relations.len > 0`. O(pages × relations). |
| `artifactSchemaVersion(result, versions)` | Returns the conditional schema version string. |
| `artifactCompilerId(result, versions)` | Returns the conditional compiler-id string. |
| `endpointLess(a, b)` | Lexicographic endpoint comparison by `(type.name, value)`. Used in semantic-edge sort. |
| `endpointEq(a, b)` | Equality check for endpoints; used in semantic-edge sort tie-breaking. |
| `writeOptionalString(buf, gpa, s)` | Writes a JSON string or `null` for `?[]const u8` fields. |
| `writeU32Array(buf, gpa, values)` | Serializes `[]const u32` as a compact JSON array without indentation (e.g., `[0,1,2]`). |
| `writeEndpoint(buf, gpa, endpoint, indent_level)` | Serializes an endpoint as a two-key object `{"type": "...", "value": "..."}` at the given indent depth. |


***

## Dependency graph (imports)

```text
src/ir_emit.zig
    ← @import("std")              (standard library only)
    ← @import("graph.zig")        (buildNav, freeNav)
    ← @import("jsonout.zig")      (all primitive JSON writers)
```

`ir_emit.zig` does **not** import:

- `pipeline.zig` (intentional inversion; prevents cycle)
- `render.zig`, `compile.zig`, `rag.zig`, or any I/O module
- Any C ABI or external library

***

## JSON output structure

### `manifest.json` schema shape (IR 0.2.0 / 0.3.0)

```json
{
  "schemaVersion": "0.2.0",
  "compiler": "boris/0.8.1",
  "contentRoot": "content",
  "pageCount": 3,
  "pages": [
    {
      "index": 0,
      "id": "guides-intro",
      "sourcePath": "guides/intro.md",
      "role": "trunk",
      "parent": null,
      "title": "Introduction",
      "status": null
    }
  ]
}
```


### `graph.json` schema shape (base IR; `relations` key omitted when no semantic relations)

```json
{
  "schemaVersion": "0.2.0",
  "frozen": true,
  "nodes": [ ... ],
  "edges": [ { "from": {"type":"page","value":"..."}, "to": {...}, "kind": "parent" } ],
  "reverseIndex": [ { "target": {"type":"page","value":"..."}, "incomingEdges": [0,2] } ],
  "nav": [ { "index": 0, "id": "...", "breadcrumb": [^1_0], "children": [1,2], "siblings": [] } ]
}
```

When semantic relations are present, a `"relations"` array follows `"nav"`.

### `build-report.json` schema shape

```json
{
  "schemaVersion": "0.2.0",
  "ok": true,
  "contentRoot": "content",
  "outDir": ".boris",
  "pageCount": 3,
  "errorCount": 0,
  "diagnostics": []
}
```


***

## Allocator and ownership analysis

All three renderers use the same ownership pattern:

1. `var buf = std.ArrayList(u8).empty;` — zero initial capacity, GPA-backed
2. `errdefer buf.deinit(gpa);` — frees partial buffer on any error return
3. Every append calls `gpa` directly; no arena is created inside these functions
4. `return try buf.toOwnedSlice(gpa);` — transfers ownership to caller; buf is reset to empty (not freed)

`renderGraph` additionally:

- Calls `graphmod.buildNav(gpa, ...)` — allocates nav array and its sub-slices under `gpa`
- `defer graphmod.freeNav(gpa, nav)` — releases nav before return in all paths (success and error)
- The `semanticedges` ArrayList inside `renderGraph` is deferred-deinited; any OOM during append will trigger the errdefer on `buf` and the defer on both `nav` and `semanticedges`

**Potential double-free risk (uncertain):** If `renderGraph` returns an error after `buildNav` succeeds but before the `errdefer buf.deinit` fires, `nav` is freed by its `defer` and `buf` is freed by its `errdefer`. This ordering is safe in Zig: defers and errdefers execute in LIFO order. No double-free risk is structurally present.

**No arena re-use:** The renderers never call `arena.reset()` or touch any arena passed through `result`. The caller's pipeline arena is not visible to these functions.

***

## Determinism properties

The following determinism properties are **structurally enforced** by the code:

- **Fixed key order:** JSON object keys are written by explicit `buf.appendSlice` calls in source order, not via a map iterator. Output key order is constant for a given schema version.
- **Page order:** `result.pages.items` is iterated sequentially; ordering is the caller's responsibility (pipeline freezes in entity-id alphabetical order).
- **Edge order:** `result.edges.items` is iterated sequentially; ordering is the caller's responsibility (pipeline sorts and deduplicates before freeze).
- **Nav order:** `graphmod.buildNav` produces entries parallel to `result.pages.items` (same index); determinism inherits from page order.
- **Semantic edge sort:** `std.sort.block` is called on the assembled `semanticedges` list with a total comparator `(from, to, kind)`. Provided the comparator is total (it is, by lexicographic composition), the output order is deterministic for a given input set regardless of `page.semantic_relations` insertion order within the source data.

The following are **assumed, not proven by the renderer itself:**

- That `result.pages.items` is in canonical entity-id order (proven by `pipeline.freeze` and hardening test)
- That `result.edges.items` is deduplicated and sorted (proven by `pipeline.freezeDependencyIndex`)
- That string values in page fields contain no embedded NUL bytes or other characters that would produce malformed JSON escaping (not tested for adversarial inputs)

***
