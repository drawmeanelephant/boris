---
title: "`src/rag.zig` surface and execution"
id: docs/boris/src/rag/surface-and-execution
parent: docs/boris/src/rag
status: draft
tags: [boris, zig, source-reference, surface, rag]
---

# `src/rag.zig` surface and execution

## Internal structure and pipeline

### Phase 1 — Shared compile

`pub fn run` begins by calling `pipeline.compile` with `content_root`, `quiet`, and `input_format` options, receiving a `pipeline.Result`. If `result.compile.ok` is `false`, the function returns immediately with `stats.published == false` and the prior output directory intact. The shared compile path runs: content-directory scan → per-file frontmatter parse → PageDb promotion → `graph.validate` → dependency resolution → graph freeze. These steps are not duplicated in `src/rag.zig`.

### Phase 2 — Staging

A sibling staging directory named `{out_dir}.boris-rag-stage` is created. All five segment types are written into it with all file handles closed before any rename operation is attempted. The order is:

```text
exportSystemDocs       → stage/system/**
exportContentPages     → stage/content/pages/**
exportGraphDocs        → stage/graph/entity-catalog.md, stage/graph/relations.md
exportUploadGuide      → stage/UPLOAD-GUIDE.md
exportIndex            → stage/INDEX.md          (uses sorted catalog)
exportCatalogJsonl     → stage/catalog.jsonl
exportCatalogMeta      → stage/catalog_meta.json
```


### Phase 3 — Publish (`publishCorpus`)

`publishCorpus` implements a multi-fallback rename-or-copy strategy described in the function doc-comment:

1. **Fast path:** `tryRenameDir(stage, out_dir)` — succeeds when `out_dir` does not yet exist or the OS allows atomic replacement.
2. **Move-aside:** rename `out_dir` → `out_dir.boris-rag-prev`, rename `stage` → `out_dir`, delete prev. On install failure, restore prev. On dual failure, returns `error.RagPublishSwapFailed`.
3. **Cross-volume copy:** materialize `out_dir.boris-rag-next` via `copyTreeFiles`, then swap using move-aside; cleans up leftovers.

The function's own comment states: "Cross-volume **atomic** replace is still not claimed. Concurrent readers may briefly observe the previous tree moved aside during the swap window." This is consistent with the engineering principle of not claiming safety properties without evidence.

### Body transformations

Three text transformations are applied to each content page before export:

- **`stripLeadingAtxH1`**: removes the first non-blank ATX H1 heading (the title is taken from frontmatter or entity ID, so the source H1 is redundant).
- **`demoteAtxH1ToH2`**: converts any remaining ATX H1 lines to H2, so the injected metadata-owned `# Title` in `renderContentDocument` is the sole H1.
- **`exportBodyForRag`**: iterates `aside.Segment` values; `.markdown` segments go through the above two transforms; `.aside` segments become `:::kind{id="…"}` directive blocks (non-round-trippable export representation); `.details` segments become similar directives.

These transformations are duplicated between `src/rag.zig` and `src/rag_emit.zig`. The `rag.zig` versions are used in `exportBodyForRag`; the `rag_emit.zig` versions are used in `renderContentDocument`. The duplication is structural — `rag.zig` calls `rag_emit.renderContentDocument`, which internally calls `rag_emit.renderBody`, so the `rag.zig` copies of `stripLeadingAtxH1` and `demoteAtxH1ToH2` are **dead code** in the content page path (the `exportBodyForRag` function and its helpers in `rag.zig` are not called by `exportContentPages`). The functions are present but the path that calls them is not exercised by any test in `rag.zig`. This is a latent inconsistency, not a confirmed defect; it requires inspection of whether `exportBodyForRag` is called anywhere in the module. Reading the code: `exportBodyForRag` is defined but no call site within `src/rag.zig` exists. It is unused production code.

Similarly, the `exportGraphDocs` function constructs a `doc` `ArrayList` that is fully populated but then discarded (`defer doc.deinit(gpa)`), because the actual file content is produced by `rag_emit.renderEntityCatalog` and `rag_emit.renderRelations`. The manual buffer construction constitutes dead code.

### Allocator discipline

`run` manages two allocators:

- `gpa` (caller-provided): used for transient buffers, the `catalog` `ArrayList`, and `stage_rel`; freed explicitly with `defer gpa.free(...)`.
- `result.arena` (ArenaAllocator wrapping gpa): used for durable strings in catalog entries (`appendCatalog` dupes all strings into the arena). Arena lifetime matches `RagResult`; the caller must call `result.deinit()`.

`exportContentPages` uses an inner `doc_arena` that is reset per page (`doc_arena.reset(.free_all)`) to avoid accumulating per-page scratch allocations. `rag_emit.renderContentDocument` returns a GPA-owned `[]u8` that is freed by the caller immediately after writing (`defer gpa.free(doc)`).

## Key public types

### `RagOptions`

```zig
pub const RagOptions = struct {
    content_root: []const u8 = "content",
    out_dir:      []const u8 = "rag",
    system_docs_dir: []const u8 = "docs/rag/system",
    quiet: bool = false,
    input_format: identity.InputFormat = .markdown,
};
```

Missing `system_docs_dir` is not an error; `exportSystemDocs` catches `error.FileNotFound` and skips silently.

### `RagStats`

Carries post-export counts: `system_docs`, `content_pages`, `graph_docs`, `catalog_entries`, and the boolean `published`. `published` is set only after `publishCorpus` succeeds.

### `RagResult`

Owns both the arena and the `pipeline.Result` (`compile`). `ok()` returns `compile.ok and stats.published`. `deinit()` tears down both. The caller must not access `compile.pages` or `diagnostics` after `deinit`.

### `CatalogEntry`

A type alias for `rag_emit.CatalogEntry`. Eight fields with fixed normative order: `rag_id`, `rag_path`, `category`, `title`, `entity_id`, `role`, `parent_entry`, `tags`. All fields are `[]const u8`; `entity_id`, `role`, `parent_entry`, and `tags` default to empty string.

## Determinism properties (as documented)

The module doc-comment claims determinism via four explicit stable sorts:

- System seeds → normalized relative rag path (lexicographic)
- Content pages → entity id (order inherited from `pipeline.compile` freeze)
- Graph edges → source id then target id
- Catalog rows → `rag_path` (via `rag_emit.sortCatalogByRagPath`)

The "no timestamps, absolute paths, hostnames, random values, or hash-map / filesystem walk order" claim is structural (no calls to clock, environment, or random APIs are visible in the source), but filesystem walk order is mitigated only by collecting paths into an `ArrayList`, sorting them, and then processing in sorted order — this is **structurally checked** by the code for system seeds but **relies on `pipeline.compile` to have already sorted pages** for content pages. Whether `pipeline.compile` guarantees sorted order after freeze is not verified in this file; it is taken as a contract.

The dual-run determinism test (`rag export: valid corpus, dual-run determinism…`) calls `run` twice with the same fixtures and asserts `expectDirsByteIdentical`. This is a **directly demonstrated** test of byte-level determinism for the specific fixture set used.

## Detailed analysis: selected behaviors

### Failure gate — no corpus on content error

**Behavior:** `run` calls `pipeline.compile`. If `result.compile.ok` is `false`, it returns without creating a staging directory or writing any files. The prior `out_dir` is untouched.

**Structural check:** The `if (!result.compile.ok)` branch exits immediately before any `ensureDirPath` or file-write call.

**Directly demonstrated:** The `rag vs IR` test seeds `rag_out` with `stale-marker.txt`, runs `rag.run` over `duplicate-ids` content, and asserts that `stale-marker.txt` still exists and `catalog.jsonl` does not.

**Residual gap:** The test uses a content-validation failure (duplicate IDs). I/O failures during the compile phase (e.g., unreadable content root) are handled by `pipeline.compile` and would also return `!ok`, but no separate RAG-specific test exercises this path.

### Staging → publish sequence

**Behavior:** All files are written to `{out_dir}.boris-rag-stage`. The `stage_dir` handle is closed inside a scoped block before `publishCorpus` is called. `publishCorpus` then attempts a rename in preference to deletion.

**Structural check:** The file-writing block ends with `}` closing `stage_dir` before `publishCorpus` is invoked. `publishCorpus` deletes any leftover `.boris-rag-prev` and `.boris-rag-next` before beginning a new swap.

**Directly demonstrated (partial):** The `rag export against fixtures/content/valid` test calls `run` twice to the same `out` path and then asserts that neither `.boris-rag-prev` nor `.boris-rag-next` exists after success. This proves the happy-path cleanup but does not exercise the error branches of `publishCorpus` (failed rename after move-aside, failed copy-tree, `error.RagPublishSwapFailed`).

**Uncovered by tests:** The `error.RagPublishSwapFailed` return and the cross-volume copy fallback inside `copyTreeFiles` are not exercised by any test visible in `src/rag.zig`. Their correctness is contract-only.

### H1 normalization — leading strip and demotion

**Behavior:** For each content page, the first non-blank ATX H1 (the source title) is stripped. Remaining ATX H1s are demoted to H2. The content document is then rendered with a fresh `# {title}` header from the page's `title` frontmatter field (or entity ID).

**Structural check:** `stripLeadingAtxH1` and `demoteAtxH1ToH2` are called from `rag_emit.renderBody` via `rag_emit.demoteAtxH1ToH2(rag_emit.stripLeadingAtxH1(md), allocator)`. The copies of these functions in `src/rag.zig` (used in `prepareContentBody` and `exportBodyForRag`) appear to be dead code — `exportBodyForRag` is defined but not called from `exportContentPages` or any other function in the file.

**Directly demonstrated:** The dual-run test asserts `countAtxH1(body) == 1` for all four content pages and verifies that `m-mid.md` contains `## Nested H1 Becomes H2` but not `Source H1 Should Vanish`.

**Uncertain:** Whether `prepareContentBody` / `exportBodyForRag` are dead code is directly readable from the source — no call site for `exportBodyForRag` exists in `src/rag.zig`. The `prepareContentBody` function is called by the `"prepareContentBody strips…"` unit test, confirming the logic is correct in isolation, but confirming it is not on the live content export path.

### Aside → `:::kind` directive conversion

**Behavior:** `&lt;Aside kind="tip" id="z1">…&lt;/Aside&gt;` in source is parsed by `aside.tokenizeBody` into `.aside` segments. On export, `rag_emit.renderBody` calls `aside.formatRagDirective`, emitting `:::tip{id="z1"}` blocks.

**Structural check:** `exportContentPages` calls `aside.tokenizeBody` and passes `tok.segments` to `rag_emit.renderContentDocument`, which calls `renderBody`.

**Directly demonstrated:** The dual-run test reads the exported `content/pages/z-last.md`, asserts `:::tip{id="z1"}` is present, `Tip body.` is present, and `&lt;Aside` is absent.

**Residual gap:** Only one aside kind (`tip`) is tested in `src/rag.zig`'s fixture. Behavior for `.details` segments, malformed asides, or asides with no `id` attribute is exercised by `src/aside.zig` tests, not here.

### System seed sort order

**Behavior:** System seed files are discovered by `sys_dir.walk`, collected into a `rels` `ArrayList`, sorted by normalized relative path, and then processed in order.

**Directly demonstrated:** The dual-run test writes `b-second.md` before `a-first.md` to the system directory (deliberate reverse order), then asserts that `system/a-first.md` appears before `system/b-second.md` in `catalog.jsonl`.

### Catalog sort and field order

**Behavior:** `rag_emit.sortCatalogByRagPath` is called after all segments are appended, sorting all entries by `rag_path` lexicographically. `catalog.jsonl` is then written in that order with the fixed field sequence: `rag_id`, `rag_path`, `category`, `title`, `entity_id`, `role`, `parent_entry`, `tags`.

**Directly demonstrated:** The dual-run test iterates every JSONL line and checks that `rag_path` values are strictly ascending and that all eight field keys appear in order at increasing byte positions within the line. The `catalog.jsonl field order and string escaping` unit test also verifies exact byte-equality for a single entry including `\"` and `\n` escaping in the title.

### `normalizeRelPath`

**Behavior:** Converts path separators to `/`, collapses duplicate separators, and strips leading `./` and `//`. Used to normalize walker-reported paths for cross-platform determinism.

**Not directly tested in this file.** The function is called from `exportSystemDocs` and `collectRelFiles` but no isolated unit test exercises it. Correctness is inferred from structural reading only.

## Known structural issues (from code inspection)

1. **`exportBodyForRag` is unused.** The function and its helpers (`prepareContentBody`, `countAtxH1`, `isAtxH1Line`, `stripLeadingAtxH1`, `demoteAtxH1ToH2`) are defined in `src/rag.zig` but the content export path calls `rag_emit.renderContentDocument`, which has its own copies of the same logic. `exportBodyForRag` has no call site in the file. The unit test `"prepareContentBody strips leading H1 and demotes extras"` tests the local copy in isolation, confirming the logic is correct but not that it is on the live export path.
2. **`exportGraphDocs` builds dead buffers.** Both the entity-catalog and relations sections populate `doc` `ArrayList` objects with the complete document text, only to discard them with `defer doc.deinit(gpa)`. The actual file bytes come from `rag_emit.renderEntityCatalog` and `rag_emit.renderRelations`. The local buffer construction has no effect on output.
3. **`exportIndex` also builds a dead local buffer.** The function assembles a complete `INDEX.md` in a local `doc` buffer then calls `rag_emit.renderIndex` to produce the real output. The local buffer is discarded.

These are potential follow-up items, not confirmed defects. The output is correct because the `rag_emit` renderers are authoritative; the dead local buffer code merely wastes allocations.
