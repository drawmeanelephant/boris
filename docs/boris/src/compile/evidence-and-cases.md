---
title: "`src/compile.zig` evidence and cases"
id: docs/boris/src/compile/evidence-and-cases
parent: docs/boris/src/compile
status: draft
tags: [boris, zig, source-reference, evidence, compile]
---

# `src/compile.zig` evidence and cases

## Control flow

### Single-target `compileHtmlSite`

```text
validateLayoutPath(layout + rules)
loadLayoutOnce
PageDb + loadAndPromoteFormat
freezeSiteFromPageDb (nav material if chrome or rules)
compilePagesWithSite
  → read layout_bytes
  → compilePagesInner(shared=null → local SharedCompileState.init)
```


### Multi-target `compileHtmlSiteMulti`

```text
target_mod.validateTargets → plans
loadAndPromoteFormat once
freezeSiteFromPageDb(..., include_nav_material=true) once
SharedCompileState.init once
preflight rejectMixedThemeRoots + selectLayout every page/target
for each plan (sorted by validateTargets):
  load declared layouts into layout_cache
  compilePagesWithSharedAndSite(...)
aggregate: LayoutSelectionFailed | MultiTargetIoFailed | MultiTargetCompilationFailed
```


### `compilePagesInner` (heart)

```text
open content_dir; create dist; rejectSymlinkAlongPath(dist)
scrubStaleAtomicTemps(dist)
create sibling {dist}.boris-stage; errdefer deleteTree
load all declared layouts; selectLayout per page → page_layouts / bytes / paths
themeRootFromLayoutPath; loadThemeBundle; requireReferencedAssets; checkAssetPageCollisions
copy theme assets → stage
loadSiteAssets; collisions vs pages/theme; copy → stage
theme fingerprint material per layout
shared = shared_opt or SharedCompileState.init
if incremental: parse .boris-cache/manifest.json if format_version matches
                 parse heading-harvest.json if format matches
buildSiteHeadingIndex(prior harvest)
precreateOutputDirs(stage)
for each page:
  wiki referenceMaterialMulti (+ fragment validate) → ref_material
  content_asset.rewriteImageLinks validate
  computePageFingerprintThemeInput(target, selected_layout, entity, source,
      includes+ref, layout_bytes, nav_material?, theme_material, textile id?)
  compare prior entry fingerprint + selected_layout + output_digest vs on-disk HTML
  is_dirty[i] = !skip
if incremental: expandDirtySet
jobs>1 ? parallelWorker pool writing stage : sequential Whiteboard loop
if incremental: write staged manifest + heading-harvest (atomic createFileAtomic)
publishStageTree(stage → dist)
stale HTML scrub (manifest orphans or full walk)
scrubOrphanThemeAssets; scrubOrphanContentAssets
deleteTree(stage)
return CompileStats
```


### Parallel path

```text
ParallelContext { mutex, next_page_index, shared_error, is_dirty, page_layouts, site, heading_index, theme, content_assets }
spawn min(jobs, n) threads
each: own doc_arena; claim index; if dirty renderAndPublishPage → stage; reset free_all
first error wins shared_error; workers stop
coordinator joins; propagates error
```

Each Whiteboard arena is thread-local; Oliver rendering is pure with no global state, so parallel page workers render concurrently without serialization.

## Test harness construction

- Root: `src/compile.zig` module tests; Oliver render seam linked.
- Fixtures: temp dirs under `.zig-cache/tmp/…`, tree writes, some committed fixtures (`docs/contracts/fixtures/theme-site/…`, sample `content/` + `layouts/main.html`).
- Helpers: `writeTreeFile`, `readAllFile`, `observeWhiteboardLifecycle`, multi-run byte compare.
- No hostile C engine in this module’s default test link.

## Tested declarations and entry points (representative)

| Declaration or test | Kind | Purpose | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- |
| `isContentCompileFailure` unit | test | Classify content vs I/O vs usage | Parse/layout content true; AccessDenied/OOM false; selection errors false | Exit-code mapping support for multi-target |
| Whiteboard isolation / PageDb survives free_all | test | Two pages unique markers; metadata pointers stable after compile | Markers not cross-contaminated; titles/tags intact; last_reset_capacity 0 | Memory model |
| Many small + one large whiteboard | test | Capacity after free_all | after reset 0; peak large > 1KiB | Allocator observation only |
| Output paths via safeOutputRelativePath | test | nested content path | Nested HTML under safe relative path | identity/PageDb |
| HTML rejects invalid parent | test | missing trunk parent | `GraphValidationFailed` | Graph gate on HTML |
| Site nav/breadcrumb forest | test | trunk+satellite layout chrome | Nav/breadcrumb/title present | Feature 6 |
| Unified multi-construct dual jobs | test | tables/footnotes/… jobs 1 vs 8 | Byte-identical HTML; markers; no cross-talk | Parallel determinism smoke |
| `compileHtmlSiteMulti` success + collision | test | two targets; duplicate out dir | Dual outputs; `TargetOutputCollision` | Multi-target |
| Feature 9 heading fragments | many tests | resolve, missing, empty, fenced literal, jobs, include-borne, manual id encode, include-introduced heading, no-frag skip | Correct hrefs/ids or `ReferenceFailed` | Wiki + harvest path |
| Heading harvest incremental \#58 | test | cold/warm/no-op; body text change | Warm 0 pages written; harvest stable then updates | Harvest cache |
| F9.1 theme-site fixture | test | committed theme fixture jobs 1 and 4 | 5 pages; asset hrefs; metadata; footer | Theme product path |
| F9.1 multi-target theme isolation | test | two themes | CSS/footer isolated; no leak | Target isolation |
| F9.1 asset collision | test | theme asset path = page output | `AssetCollision` | Collision gate |
| F9.1 asset change dirties FP | test | CSS v1→v2 incremental | pages_written 0 then 1; file v2 | Theme material in FP |
| F9.1 legacy layouts/main.html | test | sample content | Renders; no required `assets/` | Backward compatible layout |
| Layout-rule hostile suite | external `layout_select_hostile_test.zig` | H5–H10 | Path reject, multi-target rules, incremental layout change, stale scrub, full=inc trees | Calls `compileHtmlSite` / Multi |

*(File contains additional incremental, publish-failure, and fixture tests beyond this table; names in bundle include multi-target, nav emit, theme adversarial trees.)*

## Hostile-case / boundary walkthroughs

### Graph validation failure before render

**Injected behavior:** Satellite `parent: missing-trunk`.
**Boundary:** `freezeSiteFromPageDb` after promote.
**Expected:** `error.GraphValidationFailed`; no successful site publish.
**Forbidden:** Publishing HTML with invalid forest.
**Evidence:** directly demonstrated.
**Gap:** Does not re-list every graph diagnostic code (covered in `graph.zig`).

### Whiteboard reset on error / no final file

**Injected behavior:** `test_fail_render_at` / `test_fail_publish_at`.
**Boundary:** `renderAndPublishPage` / assemble publish.
**Expected:** Error return; prior final preserved where seeded; arena reset by caller.
**Forbidden:** Leaving Whiteboard slices in PageDb; publishing half-written final without assemble rules.
**Evidence:** designed hooks + assemble tests; compile-level tests assert isolation.
**Gap:** Exact matrix of every error path vs stage cleanup is large; errdefer stage delete is structural.

### Incremental skip requires content digest

**Injected behavior:** Matching fingerprint but wrong/missing on-disk digest.
**Boundary:** skip_render gate in fingerprint loop.
**Expected:** Re-render.
**Forbidden:** Trusting fingerprint alone when HTML replaced.
**Evidence:** structurally checked in code; digest equality path tested via warm no-op builds.
**Gap:** Explicit “corrupt same-size file” fixture may live only implicitly.

### Heading harvest cache hit skips rendering

**Injected behavior:** Warm incremental with unchanged harvest keys.
**Boundary:** `buildSiteHeadingIndex` prior_map key compare.
**Expected:** `pages_written == 0` on no-op; harvest file byte-stable; fragment hrefs remain.
**Forbidden:** Re-rendering every fragment target on no-op.
**Evidence:** directly demonstrated (\#58 test).
**Gap:** Does not prove harvest file atomicity under crash mid-write beyond createFileAtomic usage.

### Missing heading / empty fragment / missing entity

**Injected behavior:** `&#91;&#91;target#does-not-exist&#93;&#93;`, `&#91;&#91;index#&#93;&#93;`, `&#91;&#91;nosuch#h&#93;&#93;`.
**Boundary:** `referenceMaterialMulti` / validate_fragments during fingerprint prep.
**Expected:** `ReferenceFailed`.
**Forbidden:** Silent broken href.
**Evidence:** directly demonstrated.

### Parallel jobs byte identity

**Injected behavior:** Same tree jobs=1 vs jobs=8 twice.
**Boundary:** `parallelWorker` + per-page Whiteboard arenas.
**Expected:** Identical HTML bytes; page markers isolated.
**Forbidden:** Cross-page buffer reuse; nondeterministic nav order from races.
**Evidence:** directly demonstrated for fixture set.
**Gap:** The D4 parallel smoke test demonstrates byte-identical output under `--jobs`; Oliver is a pure library with no global state, so concurrent renders on separate arenas are safe by construction.

### Multi-target output collision

**Injected behavior:** Two targets same `output_dir`.
**Boundary:** `validateTargets` before discovery.
**Expected:** `TargetOutputCollision`.
**Forbidden:** Partial dual publish into one tree.
**Evidence:** directly demonstrated.

### Theme asset collision with page output

**Injected behavior:** Theme asset path equals page HTML output path.
**Boundary:** `checkAssetPageCollisions`.
**Expected:** `AssetCollision`.
**Evidence:** directly demonstrated.
