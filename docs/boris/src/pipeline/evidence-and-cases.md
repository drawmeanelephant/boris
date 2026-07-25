---
title: "`src/pipeline.zig` evidence and cases"
id: docs/boris/src/pipeline/evidence-and-cases
parent: docs/boris/src/pipeline
status: draft
tags: [boris, zig, source-reference, evidence, pipeline, compiler]
---

# `src/pipeline.zig` evidence and cases

## Embedded tests

### Test helpers

| Helper | Purpose |
| :-- | :-- |
| `expectCode(result, code)` | Scans `result.diagnostics` for a matching `diag.Code`; returns `error.TestExpectedDiagnostic` if absent |
| `hasCode(diags, code)` | Boolean variant of `expectCode` (unused in current tests but present) |
| `outRel(gpa, tmp, name)` | Formats a TmpDir-relative output path as `.zig-cache/tmp/{sub_path}/{name}` |
| `fileExists(io, dir_path, name)` | Non-throwing stat check; returns `false` on any error |
| `readOutFile(io, gpa, dir_path, name)` | Opens directory and reads named file; propagates errors |

### Test inventory

| Test name | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `e2e valid fixture builds three JSON artifacts` | E2E / golden | Full happy-path build and JSON shape | `docs/contracts/fixtures/valid/content`, 3-page fixture | `ok`, `graph_frozen`, `published_graph_ir`, 3 pages, all 3 files exist; JSON field order and values verified; no absolute paths in output | Artifact publication, manifest/graph JSON shape, deterministic node ordering, staging rename, schema version embedding |
| `Textile mode preserves graph identity and fails closed` | E2E / error path | Textile acceptance and rejection | Valid 2-page Textile fixture; invalid/table.textile fixture; mixed-extension fixture | Valid: `ok`, 2 pages, `.textile` source paths; invalid: `!ok`, `ETEXTILE` at line 4 col 1; mixed: `ETEXTILE` as first diagnostic; rejected: no manifest/graph published | Textile adapter integration, failure-mode gating, diagnostic line mapping |
| `F8 graph-native fixture matches full graph golden` | E2E / golden diff | Byte-exact graph output against checked-in expected file | `docs/contracts/fixtures/graph-native-dependencies/content`, 5 edges, 4 reverse-index entries | `result.edges.items.len == 5`, `result.reverse_index.items.len == 4`; `graph.json` byte-identical to `expected/graph.json` | Edge accumulation, reverse-index construction, complete JSON determinism |
| `include and wiki failures prevent dependency graph freeze and publication` | E2E / error path | Missing include + missing wiki reference gating | Temp dir with single `index.md` containing ``&#123;&#123;include includes/missing.md&#125;&#125;`` and ``&#91;&#91;missing/page&#93;&#93;`` | `!ok`, `!graph_frozen`, `!published_graph_ir`, `EINCLUDEMISSING`, `EREFERENCEMISSING` diagnostics, no manifest/graph files | Dependency resolution error gating, artifact suppression on failure |
| `Feature 9 IR: wiki fragment still emits page reference edge only` | Unit / edge semantics | Fragment-qualified wikilinks collapse to single page edge | Temp content with ``&#91;&#91;guides/t#sec&#93;&#93;`` and ``&#91;&#91;guides/t&#93;&#93;`` from index | `ok`, exactly 1 `"reference"` edge `page:index → page:guides/t` | Fragment stripping in wikilink scanning, edge deduplication |
| `duplicate id fails and does not publish graph-dependent IR` | E2E / stale-IR cleanup | Stale artifact removal on validation failure | Pre-existing `manifest.json` and `graph.json` in output dir; `docs/contracts/fixtures/duplicate-ids/content` | `!ok`, `!published_graph_ir`, `EDUPLICATEID`, no manifest/graph after run, build-report has `ok: false` | Stale IR removal, `publishArtifacts` failure path |
| `invalid graph fixtures emit stable categories` | E2E / diagnostic mapping | All invalid-graph fixture types map to stable codes | 9 fixture roots (missing-parent, self-parent, satellite-of-satellite, cycles, longer-cycle, case-id-collision, duplicate-id, cycle, satellite-of-satellite from fixtures/) | Each produces `!ok`, `!published_graph_ir`, expected `diag.Code` | Diagnostic code stability across all topology error categories |
| `determinism: two builds produce byte-identical IR` | Regression / determinism | Two runs on identical input yield identical files | Same `content` path, two distinct `out_dir`s | `manifest.json` and `graph.json` byte-identical; `build-report.json` renderer-identical when `out_dir` is normalized | Output determinism, no ambient entropy (timestamps, hash seeds, pointer values) |
| `render twice is byte-identical (no ambient entropy)` | Unit / render | Rendering the same `Result` twice yields identical bytes | One run of valid fixture; render `graph` and `manifest` twice each | All four render calls return identical byte slices | Renderer idempotency, no internal mutable state or random seeds |
| `fixtures/content/valid builds and orders by id` | E2E / ordering | ID-sorted page ordering | `fixtures/content/valid`, 4 pages | 4 pages in expected ID order: empty-no-fm, home, nested/deep/page, satellite-child; roles correct | Graph freeze sort, trunk/satellite role assignment |
| `promoted metadata survives source buffer free (via PageDb unit + pipeline)` | Regression / lifetime | Title strings readable after source buffers freed | Valid 3-page fixture | `result.pages.items[^1_0].title.? == "Introduction"`, etc. | Arena promotion correctness, metadata lifetime after GPA buffer free |
| `parser error fixtures map to EFRONTMATTER / EINVALIDPATH` | E2E / diagnostic mapping | Parser error → diagnostic code mapping | 7 fixture roots (invalid-status, invalid-tags, trailing-comma, invalid-id, unsupported-syntax, duplicate-key, malformed-frontmatter) | Each produces `!ok`, `!published_graph_ir`, expected code | `parserCategoryToCode` mapping completeness |
| `missing content root is EIO and does not publish graph IR` | E2E / error path | Missing content directory handling | Non-existent `__no_such_root__` fixture path | `!ok`, `failure == .io`, `EIO` diagnostic, no manifest/graph | Scanner `ContentDirMissing` → EIO diagnostic mapping |
| `per-file read failure remains EIO with I/O failure classification` | Regression / POSIX | Mode-000 file produces `EIO` classification | Temp dir with `unreadable.md` (permissions 000); POSIX-only (skipped on Windows and privileged processes) | `!ok`, `failure == FailureKind.io`, `EIO` diagnostic | Per-file I/O failure classification, `failure` field priority |
| `golden expected IR shape for valid fixture` | E2E / golden | JSON key presence and order, body offset, tags | Valid 3-page fixture | Manifest key order: schemaVersion, compiler, contentRoot, pageCount, pages; graph has `frozen: true`, specific `bodyOffset` values, `tags: ["guide", "intro"]` | IR field ordering, body offset accuracy, tag serialization |

## Control flow

### `compile` high-level flow

```text
compile(io, gpa, CompileOptions)
    → Result init (arena + empty lists)
    → scanner.scan → PageList
    → for each DiscoveredPage:
        readFileAlloc (gpa; deferred free)
        parser.parse → ParsedDoc
        [textile] textile.toMarkdown (tok_arena; deferred free)
        aside.tokenizeBody (tok_arena; deferred deinit)
        db.promote → PageDb entry (strings duped into retain/arena)
    → for each PageDb entry:
        result.pages.append (graph_mod.Node)
    → graph_mod.validate
    → [if ok] validateSemanticRelations
    → [if ok] resolveDependencies
        → DependencyResolver.scanPage per page
            → scanWiki (wikilinks → "reference" edges)
            → scanIncludes (include directives → "include" edges, recursive)
    → [if ok] graph_mod.freeze
    → [if ok] freezeDependencyIndex
        → append parent edges
        → sort + deduplicate edges
        → build reverse_index (GPA-owned []u32 slices)
    → return Result
```


### `run` flow

```text
run(io, gpa, Options)
    → compile(io, gpa, CompileOptions{...})
    → result.out_dir = retain.dupe(out_dir)
    → publishArtifacts(io, gpa, &result)
        → if !ok:
            delete manifest.json, graph.json from out_dir
            write build-report.json
        → if ok:
            render manifest, graph, build-report → []u8 (deferred free)
            create {out_dir}.boris-stage
            write all three to stage
            rename each stage→out_dir (CrossDevice: copy+delete)
            delete stage dir
            result.published_graph_ir = true
    → return Result
```


### Per-file scratch lifetime

```text
loop iteration:
    readFileAlloc → source []u8       (gpa; defer gpa.free(source))
    ┌ tok_arena init (gpa)
    │   textile.toMarkdown → adapted  (tok_arena; may hold adapted.markdown)
    │   aside.tokenizeBody → tok      (tok_arena)
    └ tok_arena.deinit()              ← all tok and adapted memory freed here
    db.promote(disc, final_id, ...)   ← all durable strings duped into retain
                                      ← source slice gone after loop iteration
```

No pointer into `source`, `tok`, or `adapted` survives past the iteration boundary. Diagnostic strings are duped into `retain` before any free.
