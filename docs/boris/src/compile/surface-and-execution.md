---
title: "`src/compile.zig` surface and execution"
id: docs/boris/src/compile/surface-and-execution
parent: docs/boris/src/compile
status: draft
tags: [boris, zig, source-reference, surface, compile]
---

# `src/compile.zig` surface and execution

## Memory model (normative in-module)

Documented at file head and enforced by call structure:

1. **PageDb** — long-lived retain arena for promoted metadata only (`entity_id`, title, parent, paths, tags, body_offset, graph role/index after freeze). No slices into source, parser views, Apex HTML, or writers.
2. **Whiteboard** — per-page (or per-worker) `ArenaAllocator`. Source re-read, parse/render scratch, Apex HTML, slot fragments live here.
3. **Reset** — `arena.reset(.free_all)` only after Apex returned, writes flushed, temp closed/finalized, publish attempt finished, and no caller-owned object retains Whiteboard slices. `renderAndPublishPage` never resets; callers do.
4. **Layout arena** — long-lived for loaded `assemble.Layout` views for the compile.
5. **GPA** — fingerprints hex, shared source/include bytes, staging paths, harvest snapshot, layout raw bytes, etc.

Tests observe Whiteboard `queryCapacity` after reset; process RSS is explicitly **not** claimed.

## Key public types

| Type | Role |
| :-- | :-- |
| `FrozenSite` | GPA-owned nodes/edges/nav + optional `site_nav_material`; `indexOf(entity_id)`; `deinit` |
| `CompileOptions` | target name, content/dist roots, layout path/rules, quiet, incremental, jobs, input_format, test failure injectors |
| `CompileStats` | pages_written/attempted, peak/last Whiteboard capacity |
| `RenderOptions` | optional site, heading_index, theme, page_assets |
| `CacheEntry` / `CacheManifest` | on-disk incremental manifest shape (`format_version`, fingerprint, selected_layout, output_size/digest) |
| `ParsedCache*` | JSON parse views; foreign/old `format_version` ignored → cold rebuild |
| `SharedCompileState` | multi-target shared dep index + per-page source/include bytes/paths |
| `HEADING_HARVEST_FORMAT` | `"boris-heading-harvest-v1"` side-cache (not page fingerprint format) |

## Core API surface

| Function | Kind | Purpose |
| :-- | :-- | :-- |
| `freezeSiteFromPageDb` | pub | Build nodes from PageDb → `graph.validate` → freeze → `buildNav` → sync role/index onto PageDb → optional nav material |
| `loadLayoutOnce` | pub | `assemble.loadLayout` with layout errors remapped (`LayoutMissingMarker`, …) |
| `loadAndPromote` / `loadAndPromoteFormat` | pub | scan → read → parse → `html_body.bodyForInput` gate → `db.promote`; free source per file |
| `renderAndPublishPage` | pub | Whiteboard render + slot fill + `assemble.writePageWithSlotsOpts` into given dist/stage dir |
| `compileHtmlSite` | pub | Full single-target pipeline |
| `compileHtmlSiteMulti` | pub | `validateTargets` → one promote/freeze/shared → preflight layout select all targets → sequential per-target compile |
| `compilePages` / `WithSite` / `WithShared` / `WithSharedAndSite` | pub | Lower entry points into `compilePagesInner` |
| `collectTransitIncludes` | private | DFS forward includes for fingerprint inputs |
| `buildSiteHeadingIndex` | private | Apex harvest for fragment targets; harvest-key reuse |
| `expandDirtySet` | private | Reverse-dep expansion via `cache.getAffectedPagesIndexed` |
| `publishStageTree` | private | Walk stage → rename into final; `CrossDevice` → copy+delete |
| `compilePagesInner` | private | Main stage/fingerprint/render/commit/scrub engine |

## Incremental cache contract

- Manifest path: `{dist}/.boris-cache/manifest.json` (written under stage first).
- `format_version` must equal `cache.CACHE_FORMAT_VERSION` (`boris-cache-v2-layout-rules`); else ignored.
- Skip requires: matching `entity_id`, `output_path`, `fingerprint`, `selected_layout` (if present), non-empty `output_digest` matching SHA-256 of on-disk HTML; `output_size` is prefilter only.
- Fingerprint inputs include target name, **selected** layout path/bytes, entity, source, transitive includes (sorted paths), optional site-nav material when layout has graph chrome slots, theme material, textile adapter identity when `--textile`, and wiki reference material (so title/path renames dirty linkers, including via includes).
- Asset **bytes** are not page fingerprint inputs for content-local images in the sense that image rewrite validates every build; theme referenced asset material **is** in theme fingerprint material (tests show CSS byte change dirties HTML).
- Dirty seeds expand through reverse dependency index (parent/include/reference) via `expandDirtySet`.
- Heading harvest is a **separate** side-cache: key = SHA-256(entity + source + includes + input_material); hit reuses heading ids without Apex (\#58).

## Staging and publication

- Stage directory: `{dist_dir}.boris-stage` (sibling string concat).
- Dirty HTML, theme assets, content-local assets, cache files land in stage.
- On full target success: `publishStageTree` renames files into final dist; then stale scrub on final.
- On failure: `errdefer` deletes stage; final dist left as prior successful publish (where applicable).
- Cross-device: rename failure → copy+delete; **atomic cross-volume replace is not claimed** (same honesty as IR/RAG).

## Layout rules and themes (F9.1)

- Empty `layout_rules` → one layout for all pages.
- Selection after graph freeze (roles available): `layout_select.selectLayout(entity_id, role, rules, fallback)`.
- Mixed theme roots rejected (`rejectMixedThemeRoots`).
- Ambiguous glob / duplicate selector → usage-class errors (`AmbiguousGlob`, etc.), distinct from content failures in `isContentCompileFailure`.
- Theme root derived from layout path; `&#123;&#123;asset-url&#125;&#125;` requires managed theme; footer slot from theme bundle.
- Multi-target: each target gets own asset tree and `.boris-cache` namespace under its output dir.

## Threat / failure model (compile-level)

| Category | Behavior in this file |
| :-- | :-- |
| Invalid graph parents/cycles/dups | `freezeSiteFromPageDb` → `GraphValidationFailed`; no HTML publish for that compile |
| Bad layout markers | Fail before content walk (`LayoutMissingMarker`, …) |
| Path escape in layout paths | `validateLayoutPath` at entry and on rules |
| Symlink on dist/stage path | `rejectSymlinkAlongPath` (TOCTOU shrink noted in comments) |
| Wiki missing entity/heading | `ReferenceFailed` during fingerprint/ref material or render |
| Include failures | Via dep population / body render → `IncludeFailed` |
| Theme/content asset collision or missing | Hard errors (`AssetCollision`, `ThemeRootMissing`, …) |
| Incremental corrupt same-size HTML | Digest mismatch forces re-render |
| Old cache format | Cold rebuild |
| Injected test failures | No final publish / cache rollback paths under test options |
| Parallel first failure | `shared_error`; other workers stop; stage discarded on errdefer |

Untested or not fully proven here: hostile Apex outputs (covered in `apex_hostile_test.zig`); full OS symlink races; concurrent multi-process writers on same dist.

## Ownership and allocation summary

| Resource | Owner | Lifetime |
| :-- | :-- | :-- |
| PageDb strings | retain arena | whole compile |
| FrozenSite nodes/edges/nav/material | GPA / `FrozenSite.deinit` | after freeze until compile end |
| SharedCompileState sources/includes | GPA | multi-target shared or local inner |
| Layout views | layout arena | compile |
| Layout raw bytes | GPA (borrowed fallback may share caller slice) | until layouts_by_path teardown |
| Whiteboard | per page/worker arena | reset after each page |
| Stage tree | filesystem | deleted after commit or on error |
| Cache + harvest JSON | under dist `.boris-cache/` | incremental next run |
| `CompileStats` | return by value | caller |
