---
title: "`src/compile.zig` overview"
id: docs/boris/src/compile
status: draft
tags: [boris, zig, source-reference, compile]
---

# `src/compile.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/compile/surface-and-execution|Surface and execution]]
* [[docs/boris/src/compile/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/compile/review-state|Review state]]

## Executive summary

`src/compile.zig` is the HTML site rendering coordinator for Boris — the default CLI product path when bare `boris` (or `--html` / `--html-dir` / `--target`) runs. It owns layout load, content discovery and PageDb promotion, shared graph validate/freeze (Feature 6), optional layout-rule selection, theme and content-local asset publication, content-addressed incremental rebuilds, bounded parallel page workers, sibling staging publication, stale output cleanup, and the heading-harvest side-cache used for wiki fragment links. It does **not** emit IR JSON; IR remains `pipeline.zig`. It does **not** own renderer contracts; body HTML goes through `html_body` → `render.zig`.

The file exists because HTML builds must be correct before they are fast: graph validation is shared with IR/RAG; PageDb never retains parser or renderer slices; each page uses a Whiteboard arena that is reset only after Oliver returns, flush, and publish attempt; fingerprints exclude timestamps and unstable iteration; multi-target runs share one discovery/graph/fingerprint prep and isolate output trees and cache namespaces.

Primary entry points are `compileHtmlSite` (single target) and `compileHtmlSiteMulti` (validated target plans, sequential targets). Both eventually reach `compilePagesInner`, which implements staging, dirty-set expansion, jobs workers, cache/heading-harvest write, stage commit, and scrub. Test-only hooks (`test_fail_render_at`, `test_fail_publish_at`, `test_fail_cache_publish`) inject failures without production callers setting them.

The module is linked into the product binary with the Oliver-backed render seam (`build.zig` `compile` module, `linkOliver(compile_mod, oliver_mod)`). Tests run under `zig build test` via the compile test step. Confidence is high for whiteboard isolation, graph gate on HTML, incremental skip/dirty expansion, multi-target isolation, theme/asset collision, heading fragment resolve/fail, and jobs vs sequential byte identity where tests assert it. The file does not prove process-level RSS flatness (only arena `queryCapacity` after `free_all`) or cross-volume atomic publish (rename preferred; `CrossDevice` falls back to copy+delete).

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production HTML compile coordinator with large embedded integration tests |
| Conceptual domain | HTML SSG; Whiteboard memory; incremental cache; multi-target; parallel page render; theme/assets; wiki heading harvest |
| Build or test root | `compile` module in `build.zig`; product `main` → `runHtml` → this module; `zig build test` runs compile tests |
| Production runtime dependency | Yes — default CLI HTML path |
| Expected execution command | `zig build test` (unit/integration); product: `boris`, `boris --html-dir …`, `boris --target …`, `boris --incremental`, `boris --jobs N`, `boris --watch` (watch rebuilds call into compile) |
| Main collaborators | `page`, `scanner`, `parser`, `graph`, `assemble`, `render` (via `html_body`), `cache`, `dependency`, `pipeline` (dep index), `layout_select`, `target`, `theme`, `content_asset`, `html_nav`/`html_toc`/`html_body`, `wikilink`, `include`, `json_out`, `identity`, `textile` |
| Documentation depth warranted | Very high — central product path; memory and publish contracts are load-bearing |

## Role in the Boris architecture

```text
CLI (cli.zig / main.zig)
    → runHtml / multi-target
        → compileHtmlSite | compileHtmlSiteMulti
            → loadLayoutOnce, loadAndPromoteFormat
            → freezeSiteFromPageDb (graph.validate + freeze + buildNav)
            → SharedCompileState (multi) | local shared (single)
            → compilePagesInner
                → layout select, theme, content assets
                → fingerprints + incremental dirty + expandDirtySet
                → buildSiteHeadingIndex (+ harvest cache)
                → renderAndPublishPage (seq or parallelWorker)
                → stage cache + heading-harvest
                → publishStageTree → scrub orphans
```

- **Product binary:** linked; not test-only.
- **vs `pipeline.zig`:** HTML path reuses graph validation and `populateDependencyIndexFormat` for include/reference edges used in fingerprints and affected-page expansion; does not write `manifest.json` / `graph.json` IR.
- **vs `render.zig`:** never calls the renderer directly; `html_body.renderSource` does. Parallel workers each render on their own per-document Whiteboard arena; Oliver has no global state, so no mutex is needed.
- **vs `cache.zig`:** consumes `computePageFingerprintThemeInput`, `hashBytes`/`hexDigest`, `getAffectedPagesIndexed` / `NodeLookup`, `CACHE_FORMAT_VERSION`.
- **Historical:** `experimental: bool = true` remains as a marker comment lineage from milestone 9; bare CLI HTML is the product default despite that name.
