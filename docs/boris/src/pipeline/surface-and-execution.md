---
title: "`src/pipeline.zig` surface and execution"
id: docs/boris/src/pipeline/surface-and-execution
parent: docs/boris/src/pipeline
status: draft
tags: [boris, zig, source-reference, surface, pipeline, compiler]
---

# `src/pipeline.zig` surface and execution

## Public API surface

### Version constants

```zig
pub const schema_version = "0.2.0";
pub const compiler_id = "boris/0.8.1";
pub const semantic_schema_version = "0.3.0";
pub const semantic_compiler_id = "boris/0.8.1+semantic-relations";
pub const boris_version = "0.8.1";
```

These are the sole source of truth for all version strings embedded in emitted JSON. `ir_emit.zig` receives them as a struct argument from `renderManifest`, `renderGraph`, and `renderBuildReport`. Callers outside `pipeline.zig` should reference these constants rather than hardcoding version strings.

### `Options` and `CompileOptions`

`Options` includes `out_dir` for artifact publication. `CompileOptions` omits it; the two structs have otherwise identical fields (`content_root`, `quiet`, `input_format`). The split enforces that `compile` cannot accidentally write to disk — it has no `out_dir` parameter at all. `run` calls `compile` and then sets `result.out_dir` from `options.out_dir` before calling `publishArtifacts`.

### `Result`

The `Result` struct is the primary in-memory product of a pipeline execution:

- **`arena: std.heap.ArenaAllocator`** — owns all string data duped by `retain` (content roots, diagnostic messages, page IDs, titles, etc.)
- **`pages: std.ArrayList(PageEntry)`** and **`edges: std.ArrayList(DependencyEdge)`** — allocated on the child GPA, not the arena
- **`reverse_index: std.ArrayList(ReverseEntry)`** — each `ReverseEntry.incoming_edges` slice is a GPA-owned allocation freed individually in `deinit`
- **`diagnostics: std.ArrayList(diag.Diagnostic)`** — GPA-allocated list; string fields within each `Diagnostic` point into the arena
- **`ok: bool`**, **`graph_frozen: bool`**, **`published_graph_ir: bool`**, **`failure: FailureKind`** — state flags for downstream decisions (exit code, artifact presence)

The `deinit` method frees GPA lists explicitly (`pages.deinit(gpa)`, `edges.deinit(gpa)`, per-entry `gpa.free(entry.incoming_edges)`, `reverse_index.deinit(gpa)`, `diagnostics.deinit(gpa)`) and then calls `arena.deinit()`. The `child_allocator` is recovered from `arena.child_allocator` to avoid requiring callers to pass the GPA again. This is correct only if the child allocator passed at `ArenaAllocator.init` time is the same GPA used to allocate the lists — a requirement fulfilled by the `compile` function, which passes `gpa` to `.init` and uses `gpa` for all list operations.

### `FailureKind`

```zig
pub const FailureKind = enum { none, content, io };
```

Maps to CLI exit codes: `.io` → exit 3 (I/O or filesystem failure), `.content` → exit 1 (content validation error), `.none` → exit 0. The pipeline sets `.io` on scanner I/O errors and per-file read failures, preserving `.io` priority over `.content` if a per-file read failure occurs before graph validation runs.

### `PageEntry`, `Endpoint`, `DependencyEdge`, `ReverseEntry`, `EndpointType`

`PageEntry` is a type alias for `graph_mod.Node` — the resolved graph node type from `src/graph.zig`. `Endpoint` pairs an `EndpointType` (`.page` or `.source`) with a string `value` (entity ID for pages, content-root-relative path for source files). `DependencyEdge` records `from`, `to`, and `kind` (string: `"parent"`, `"include"`, `"reference"`). `ReverseEntry` records a target endpoint and a GPA-owned slice of `u32` indices into the edge list.

## Pipeline stages

The `compile` function implements the following ordered stages:

### Stage 1 — Scan

```text
scanner.scan(io, { content_root, input_format }, &scan_list)
```

Errors handled with structured diagnostic emission and early return:

- `error.ContentDirMissing` → `EIO` diagnostic, `failure = .io`
- `error.SymlinkRejected` / `error.SymlinkCycle` → `EIO` diagnostic, `failure = .content`
- `error.InvalidPath` → `EINVALIDPATH` diagnostic, `failure = .content`
- `error.InputFormatMismatch` → `ETEXTILE` diagnostic, `failure = .content`
- `error.OutOfMemory` → propagated as `error.OutOfMemory`
- Other errors → `EIO` diagnostic, `failure = .io`

All early-return paths call `diag.sortDiagnostics` before returning, ensuring stable diagnostic ordering regardless of exit path.

### Stage 2–3 — Per-file read, parse, and promote

For each `DiscoveredPage` in `scan_list`:

1. Read source bytes into a GPA buffer (`readFileAlloc`). On I/O error: `EIO` diagnostic, `result.failure = .io`, `continue`.
2. Parse frontmatter via `parser.parse(source)`. On diagnostic: map category to `diag.Code`, `continue`.
3. For Textile mode: adapt body via `textile.toMarkdown(body, tok_arena.allocator())`. On diagnostic: emit `ETEXTILE` with adjusted line number (`countLinesUpTo(source, parsed.doc.body_offset) + td.line - 1`), set `body = ""`, continue promotion (graph diagnostics still run).
4. Tokenize body via `aside.tokenizeBody(body, tok_arena.allocator())`. On `error.InvalidUtf8`: `EINVALIDUTF8`, `continue`. On tokenizer errors: map each to `ECOMPONENT` with full-source line offset, do not skip promotion.
5. Resolve final entity ID: frontmatter `id:` field if present, else `disc.entity_id`.
6. Promote durable metadata via `db.promote(disc, final_id, parsed.doc.meta, parsed.doc.body_offset)`. All string data is duped into `retain` (the arena allocator) before `source` is freed via `defer gpa.free(source)`.

The per-file scratch arena (`tok_arena`) is created and torn down inside the loop body. No parser or tokenizer slice may outlive the loop iteration; only diagnostics and `db.promote`-copied data survive.

### Stage 4 — Build provisional graph nodes

`PageDb.items()` are iterated to populate `result.pages` as `graph_mod.Node` values. Role assignment: `parent != null` → `.satellite`, else → `.trunk`. `semantic_relations` are copied from the `PageDb` entry.

### Stage 5 — Graph and semantic validation

```text
graph_mod.validate(gpa, retain, result.pages.items, &result.diagnostics)
diag.sortDiagnostics(...)
// if no errors:
validateSemanticRelations(gpa, retain, result.pages.items, &result.diagnostics)
diag.sortDiagnostics(...)
// if no errors:
resolveDependencies(io, gpa, retain, content_dir, input_format, &result)
diag.sortDiagnostics(...)
```

Each validation gate is conditioned on the prior gate producing zero errors. `resolveDependencies` is not called if graph topology or semantic relations are invalid. This prevents misleading dependency errors from appearing alongside fundamental graph errors.

`validateSemanticRelations` is a private function inside `pipeline.zig`. It detects three error categories:

- `ERELATIONSELF`: a page's semantic relation targets itself
- `ERELATIONMISSING`: a semantic relation targets a page ID not in the node set
- `ERELATIONDUPLICATE`: the same `(kind, target)` tuple appears more than once on a node (detected by O(n²) scan over per-node relations)

All three emit error-severity diagnostics with `line = 1, column = 1` (no precise frontmatter offset for relation fields — structurally noted, not a defect claim).

### Stage 6 — Freeze (clean builds only)

```text
const frozen = try graph_mod.freeze(gpa, result.pages.items, null);
defer gpa.free(frozen.edges);
try freezeDependencyIndex(gpa, &result);
result.graph_frozen = frozen.frozen;
```

`graph_mod.freeze` receives `null` for `layout_path` (layouts are not on the IR pipeline path). `freezeDependencyIndex` appends parent edges, deduplicates the edge list via sort+linear-scan, and builds the reverse index. The layout comment notes "TODO: wire layout_path when CompileOptions gains one."

Freeze is skipped entirely on failed builds. `result.graph_frozen` will be `false` and `result.published_graph_ir` will be `false` for any failed result.

### Artifact publication (`publishArtifacts`)

**Success path:** All three JSON artifacts are written to a sibling staging directory `{out_dir}.boris-stage`, then renamed (or copy+delete on `error.CrossDevice`) into `out_dir`. No partial artifact set is published: if a mid-write fails, the staging directory is abandoned. Cross-volume atomic replace is explicitly disclaimed in the doc comment.

**Failure path:** `manifest.json` and `graph.json` are deleted from `out_dir` (if present). Only `build-report.json` with `ok: false` is written. This ensures that a failed rebuild cannot leave a valid-looking prior IR set in place.

The staging directory name (`.boris-stage` suffix) is never embedded in any JSON output — verified by the `"stale-IR cleanup"` test's assertion `std.mem.indexOf(u8, graph_bytes, ".boris-stage") == null`.

## Private helpers

### `DependencyResolver` struct

An internal struct that holds the resolution context for one pipeline run. Its fields:


| Field | Type | Purpose |
| :-- | :-- | :-- |
| `io` | `Io` | Filesystem I/O handle |
| `gpa` | `std.mem.Allocator` | List/scratch allocations (freed per-iteration or on deinit) |
| `retain` | `std.mem.Allocator` | Arena for duped strings that must survive `Result.deinit` |
| `content_dir` | `Io.Dir` | Open handle to the content root directory |
| `nodes` | `[]const PageEntry` | Frozen page node slice (read-only during resolution) |
| `edges` | `*std.ArrayList(DependencyEdge)` | Output: accumulated dependency edges |
| `diagnostics` | `*std.ArrayList(diag.Diagnostic)` | Output: resolution-phase diagnostics |
| `scanned_sources` | `std.StringHashMapUnmanaged(void)` | Deduplication set for include-scanned source files |

`deinit` frees `scanned_sources` via GPA. Keys in `scanned_sources` are `retain`-duped strings; the map itself owns the key pointers only conceptually — they survive in the arena regardless. The map's value type is `void` so only the key slot needs freeing via `deinit`.

`scanWiki` calls `wikilink.scanWikiLinks`, iterates hits, and for each hit:

- If the entity ID is not in `nodes`, emits `error.ReferenceMissing` as a diagnostic via `wikilink.makeDiagnostic` and continues.
- Otherwise appends a `"reference"` edge to `self.edges`.

`scanIncludes` calls `include_mod.scanIncludeDirectives`, then for each hit:

- Appends an `"include"` edge unconditionally (even if the target is cyclic or missing — the edge is recorded, diagnostics are also emitted).
- Detects in-stack cycles via linear scan of `stack.items`.
- Detects depth limit via `include_mod.max_include_depth`.
- Skips files already in `scanned_sources`.
- Reads the source file, recurses via `scanWiki` + `scanIncludes`, then inserts the path into `scanned_sources` with a `retain`-duped key.

The recursion depth limit is enforced by `include_mod.max_include_depth` (value not directly readable from `pipeline.zig`; defined in `src/include.zig`).

`scanPage` is the per-page entry: adds `page.source_path` to the stack, then calls `scanWiki` and `scanIncludes` on the body slice starting at `page.body_offset`.

### `resolveDependencies`

Wraps a `DependencyResolver` over all pages after successful graph validation. Re-reads each source file; on I/O error emits `EIO` diagnostic and sets `result.failure = .io`. Validates `page.body_offset <= source.len` (returns `error.InvalidBodyOffset` otherwise — not a diagnostic, a hard error). For Textile mode, adapts the body slice before passing to the resolver.

### `freezeDependencyIndex`

Appends parent edges (from `page.parent` fields), sorts all edges by `(from, to, kind)`, deduplicates, and builds the reverse index. Each `ReverseEntry.incoming_edges` is a GPA-owned `[]u32` allocated via `incoming.toOwnedSlice(gpa)`. The `errdefer incoming.deinit(gpa)` / `errdefer gpa.free(owned_incoming)` pairing is used correctly to prevent leaks on allocation failure.

### `populateDependencyIndex` / `populateDependencyIndexFormat`

Public helpers used by the incremental HTML path and the `dependency.DependencyIndex` API (not the main IR pipeline). These duplicate some logic from `resolveDependencies` but operate on a pre-built node slice rather than `Result`. The Markdown-wrapper form (`populateDependencyIndex`) preserves its pre-existing call contract; the format-aware form (`populateDependencyIndexFormat`) adds Textile support.

### `countLinesUpTo`

1-based line counter: scans `source[0..min(index, source.len)]` counting `'\n'` characters. Used to convert parser- or tokenizer-relative line numbers to full-source line numbers in diagnostics. Returns `1` for index `0` (correct: first line is line 1).

### `renderManifest`, `renderGraph`, `renderBuildReport`

Thin delegation wrappers that pass the version constant bundle to `ir_emit.*` functions. All three accept `*const Result` and return `![]u8` (caller-owned, GPA-allocated). No caching or state is held.

## Allocation ownership summary

| Data | Allocator | Freed by |
| :-- | :-- | :-- |
| Arena (`result.arena`) | GPA (child) | `result.deinit()` → `arena.deinit()` |
| Page/edge/diagnostics list headers | GPA | `result.deinit()` → explicit `list.deinit(gpa)` |
| Per-entry `incoming_edges` slices | GPA | `result.deinit()` → `gpa.free(entry.incoming_edges)` |
| All string data in pages, diagnostics, edges | Arena (`retain`) | Arena teardown |
| Per-file `source` buffer | GPA | `defer gpa.free(source)` inside loop |
| Per-file `tok_arena` | GPA | `defer tok_arena.deinit()` inside loop |
| `DependencyResolver.scanned_sources` map | GPA | `resolver.deinit()` |
| Rendered JSON (`renderManifest` etc.) | GPA (caller's) | Caller's `defer gpa.free(...)` |
