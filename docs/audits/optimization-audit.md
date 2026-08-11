# Boris Optimization Audit

Audit date: 2026-08-11
Audited revision: `feature/rag-working-context-packs` (worktree, clean)
Host: Apple Silicon (arm64), 10 logical cores, 16 GiB RAM, Zig 0.16.0
Binaries: repository Debug build (`zig-out/bin/boris`) and a ReleaseFast build
compiled for measurement only (`zig build -Doptimize=ReleaseFast --prefix /tmp/…/rel`).

All timings below are from a synthetic corpus generated under `/tmp/boris-audit`
(5001 pages: 100 trunks × 49 satellites + index, default theme layout with
`{{nav}} {{breadcrumb}} {{title}} {{toc}}`, each satellite wiki-links its trunk
and carries one relative Markdown link). Every number is reproducible with that
corpus and the ReleaseFast binary; Debug numbers are labeled as such.

---

## Executive summary

Boris's compiler core (scan → parse → graph validate → IR / RAG / llms / RSS /
context) is already fast and well-shaped: a 5,001-page IR build takes **0.75 s**
(ReleaseFast), RAG-complete 0.69 s, llms.txt 0.45 s, RSS 0.28 s, and the
no-publication HTML `validate` pass renders all 5,001 pages in **4.2 s**. Graph
validation, freeze, nav construction, and dependency resolution are
hash-map-based and linear in the common cases. Startup is ~10 ms. The cost is
not in the core; it is in the **HTML publication and verification pipeline**.

The dominant measured finding is that a **default HTML build is dominated by
the post-render publication stack** (rendered-search extraction, output link
audit, artifact inventory, publication checks with Doctor page analysis,
claims/Touch Atlas/Proof Pack), and that stack is proportional to **total
published HTML bytes**. Because the default theme embeds a **full-site
`{{nav}}` in every page**, total output is **O(pages²)**, so full builds scale
superlinearly (measured: 201 pages → 0.33 s; 401 → 1.98 s; 1,001 → 21.5 s;
5,001 → >600 s, killed). Sampling shows ~98 % of build time in
`publication_checks.buildReport` (the checks stage re-reads, re-hashes, and
re-parses every published page with the Doctor analyzer).

Three compounding effects make this cliff steep:

1. **Output-size cliff (inherent to the theme design).** A site nav in every
   page means output bytes grow quadratically with page count (201 pages ≈
   5.7 MB; 1,001 pages ≈ 92 MB). Every output-proportional phase inherits it.
2. **Every post-render phase re-reads everything.** Search, link audit,
   inventory, and checks each independently open and scan the full overlay.
   On top of that, incremental digest verification reads and SHA-256-hashes
   every cached page on every incremental build. Measured: a warm no-op
   incremental build takes the same wall time as a full build (21.7 s vs
   21.5 s at 1,001 pages).
3. **Per-link and per-page allocation.** The link audit resolves every `href`
   with 4–6 allocations (`route_resolver.resolve` → `decode` → segments →
   output). With ~1,000 links per page at 1,001 pages that is ~5 M
   allocations per build, and under the default **Debug** allocator (stack
   trace capture) the same build is ~50× slower (401 pages: 98 s Debug vs
   1.84 s ReleaseFast). The repository's default `zig build` produces the
   Debug binary, so out-of-the-box builds pay this multiplier.

Where Boris is genuinely efficient: IR/RAG/graph paths, validation-only
rendering, include expansion caching within a page, heading-harvest cache
(Apex skip on key match), the evidence-chain design (claims/touches/proof pack
re-read only the small committed reports, not the tree — good), sibling
staging + rename publication, and deterministic sorted output everywhere.

Biggest scaling cliffs (10k / 100k / 1M pages): (a) full-site-nav HTML builds —
quadratic in output bytes, already >10 min at 5k pages in ReleaseFast and
untestable at 100k; (b) several genuine O(n²) algorithms that are invisible
today because constants are small but become minutes at 100k+ (incremental
manifest lookup, `findNodeById` in freeze sync, `findPage` per wiki link,
`llms.findChildren`, `rag_emit.renderRelations`, scanner `identitySeen`,
case-collision duplicate detection); (c) `graph.json`/`proof-pack.json` sizes
grow linearly per page with per-page records (~1.3 KB/page and ~1.3 KB/page
respectively → ~1.3 GB each at 1 M pages).

The single most valuable optimization is not any one phase but a **bounded,
single-read overlay pass**: read each published page once into a shared
buffer, then feed it to search, link audit, inventory digest, and checks in
memory, and parallelize the per-page consumers. Second most valuable: make the
link-audit resolution allocation-free for the common plain-relative case.
Third: pre-digest the constant fingerprint inputs (site nav material, layout
bytes) once per build instead of hashing them per page. All three are
incremental, independently landable, and directly measurable with the phase
timing instrumentation this audit recommends first.

---

## Optimization map (by subsystem)

### compiler orchestration
- `compile.zig:239` `findNodeById` — linear scan used in the per-page sync
  loop of `freezeSiteFromPageDb` (O(n²)).
- `compile.zig` `compilePagesInner` — the per-page fingerprint loop performs
  the same body scans the render path repeats (doclink/wiki/image) and hashes
  constant inputs (site nav material, layout bytes) per page.
- `compile.zig` incremental manifest lookup — linear scan over every prior
  entry per page (O(n × entries)).
- `compile.zig` `renderPageSlots` — re-reads each page source from disk even
  though `SharedCompileState.source_bytes` already holds it.

### discovery/scanning
- `scanner.zig` `identitySeen` — linear scan over visited directories per
  directory (O(dirs²)).
- `scanner.zig` — each file is stat'd twice (walker entry + `statFile`
  recheck).
- `graph.zig` `diagnoseDuplicateIds` — case-collision check scans all prior
  ids in source order (O(n²) worst case).
- `watch.zig` `PollingWatcher` — full recursive walk + stat of every file
  every 500 ms idle.

### parsing/frontmatter
- `parser.zig` is single-pass, non-allocating, and fast; the issue is that it
  is **re-run on the same bytes** (`include.bodyOfSource`,
  `include.lineBaseOfSource`, `html_body.renderSource` re-parse page and
  include files that the pipeline already parsed).

### graph
- `graph.zig` `validateSemanticRelations` — `findIndexById` per relation
  (O(n × relations)).
- `pipeline.zig` `freezeDependencyIndex` — reverse index built with a nested
  loop over all edges per unique target (O(E × T)); targets list built and
  sorted separately.
- `pipeline.zig` `findPage` — linear scan per wiki-link hit (O(links ×
  pages)); `resolveDependencies` re-reads every page source after parse and
  after `SharedCompileState`.

### body transformations
- `html_body.renderSource` scans the same body 5–6×: doclink rewrite (also
  done and discarded during dependency resolution), include expansion (reads
  include files again), wiki rewrite (also scanned during dependency
  resolution), content-image rewrite (also done and discarded in the
  fingerprint loop), Aside tokenization, Apex render.
- `include.zig` — `expandRecursive` caches per page only; the same include
  file is read once per including page (and re-read by dependency scan and by
  `SharedCompileState`).

### Apex/rendering
- Apex C-ABI rendering itself is in-process and fast; measured render of
  1,001 pages ≈ 0.23 s (validate). Not a target.
- `html_nav.renderNav` — full-site nav rebuilt per page (inherent to output,
  but every call allocates `outputPathFor` + `relativeHref` per node).

### layouts/themes
- `theme.zig` — `assetBytes` linear scan per lookup; theme bundle (walk +
  read of all assets) reloaded per target in multi-target builds.

### content assets
- `content_asset.rewriteImageLinks` runs twice per page per build (validation
  in the fingerprint loop, then the real rewrite in render) — the first is
  intentionally a fail-loud validation, but it re-scans the body.

### cache/incremental
- Measured: warm no-op incremental ≈ full build (no savings). The manifest is
  consulted per page with a linear scan; fingerprint inputs are recomputed
  from full bytes each build (necessary) but constant inputs are re-hashed
  per page (not necessary); cached outputs are read+hashed for digest
  verification (deliberate integrity check, but the cheapest redundant full
  pass).
- `expandDirtySet` is already well-optimized (comment documents the prior
  quadratic fix; uses `NodeLookup` + `by_entity_id`).

### parallel rendering
- `--jobs` only parallelizes the render phase, which measured ≈ 5 % of a
  1,001-page build (21.5 s total, render 0.23 s). jobs=4 vs jobs=1 at 401
  pages: 1.81 s vs 1.98 s. Everything after render (search, audit, inventory,
  checks, claims, touches, proof) is serial and is where the time is.

### generated projections
- `rag_emit.renderRelations` — nested loop over all pages for children
  (O(n²)).
- `llms.zig findChildren` — linear scan per page (O(n²)); `llms` also re-reads
  every source.
- `rag.zig`, `context.zig` — re-read every selected page source after compile
  already read them twice.
- `search_index.writeOverlay` — reads + parses every published page
  (output-proportional; fine given output size).

### publication verification
- `publication_checks.buildReport` — **measured dominant phase**: re-streams +
  re-hashes every artifact and Doctor-parses every HTML page. This is
  evidence-required, but its volume is O(total output) = O(n²) with a
  full-site nav.
- `artifact_inventory.collect` — hashes every file (producer-authoritative,
  required).
- claims / touches / proof pack — re-read only the small committed reports;
  evidence discipline is well-bounded. `touches.json`/`proof-pack.json` grow
  ~1 KB–1.3 KB per page (size cliff at 1 M pages, schema-bound).

### CLI/startup
- No issue. `--help` ≈ 10 ms even in Debug; no pre-dispatch filesystem work.

### diagnostics
- Failure paths allocate per finding (`formatText`), and a bad corpus can
  produce thousands of findings (a 5k-page failure emitted ~4,900
  EROUTEMISSING lines). Bounded, but the failure run under Debug never
  finished in 600 s while ReleaseFast finished in 18 s — Debug allocator
  dominates.

### tests/build tooling
- `docs/audits/test-throughput-audit.md` (already thorough): test graph is
  fully parallel; residual 16–20 s warm floor is ~8.8× shared-suite
  duplication across four roots — structural, not a build-graph defect.
- `src/incremental_scale_smoke_test.zig` — 200 pages with a content-only
  layout (`{{content}}`, no nav): does not exercise the measured cliff.
- No Boris-level benchmark/regression harness exists (only vendored Apex
  benchmarks).

### measurement/observability
- No phase timing, counters, or `--timings` surface. Every claim in this
  audit required external `sample` profiling and a hand-built corpus.

---

## Candidate backlog

### OPT-001 — Post-render publication/verification stack dominates HTML builds

**Classification:** Measured bottleneck
**Priority:** P0
**Confidence:** High
**Likely impact:** High
**Effort:** Medium
**Primary locus:** `src/compile.zig` (post-render section, ~lines 2540–2860),
`src/publication_checks.zig` (`buildReport`), `src/doctor.zig`,
`src/link_audit.zig`, `src/search_index.zig`, `src/artifact_inventory.zig`

**Observation**
After all pages render (0.23 s for 1,001 pages), the build spends almost all
remaining wall time in serial, full-tree passes: search overlay extraction,
output link audit, artifact inventory, publication checks (stream + SHA-256 +
Doctor HTML analysis of every page), then claims/touches/proof-pack.

**Evidence**
- Measured: 1,001 pages — `validate` (render-all, no publish) 0.23 s vs full
  build 21.5 s. The post-render stack is >99 % of wall time.
- `sample` of a 1,001-page ReleaseFast build at t=4 s and t=11 s: 2452/2514
  and 2481/2535 samples inside `publication_checks.buildReport`
  (`compile.zig:2788`), specifically the per-record loop (line 528) doing
  `streamFileNoFollow` + Doctor `addPage` (html_scan parsing of every page).
- 5,001-page full build: >600 s and killed; both samples (t=20 s, t=60 s) in
  the same function.

**Why it matters**
The default CLI path's wall time is decided here, not by rendering. At
corpus sizes where rendering takes seconds, the build already takes minutes.

**Scale behavior**
Proportional to total published HTML bytes (≈ O(n²) with a full-site nav):
1,001 pages ≈ 92 MB output → 21 s; 5,001 pages ≈ 500 MB output → >10 min.

**Optimization direction**
Read each published page once (staged/live overlay) into a shared buffer and
feed search, link audit, inventory digest, and checks from that single read;
parallelize the per-page consumers of each phase over the page array with
deterministic aggregation (see OPT-025). Keep the checks' independent
re-hash semantics intact (it must hash the *committed* bytes — it already
runs after commit, so it can stay, but can reuse the byte buffer that search
and audit already validated only if the commit ordering permits; otherwise
parallelize it).

**Tradeoffs / invariants**
Checks must verify the *committed* tree, so it cannot reuse pre-commit stage
buffers without proving stage == committed. Doctor analysis is evidence
(ARTIFACT_DIGEST/rendered-content findings); do not weaken it. Deterministic
finding order must be preserved (sort by record path as today).

**How to prove the improvement**
Phase timers (OPT-027) + same corpus before/after: 1,001-page full build
should drop from ~21 s toward render+single-pass floor (~1–3 s), with
byte-identical `checks.json`/`claims.json`/`touches.json`/`proof-pack.json`
and identical exit codes.

**Issue readiness:** Ready to file (with OPT-027 as prerequisite measurement)

---

### OPT-002 — Default Debug build is 35–53× slower on the HTML path

**Classification:** Measured bottleneck / Build-test feedback opportunity
**Priority:** P0
**Confidence:** High
**Likely impact:** High
**Effort:** Small
**Primary locus:** `build.zig` (default `optimize`), docs/README guidance

**Observation**
`zig build` defaults to Debug; `zig-out/bin/boris` is a Debug binary whose
DebugAllocator captures a stack trace on every allocation.

**Evidence**
- Same 401-page corpus: Debug 98.1 s vs ReleaseFast 1.84 s (~53×).
- 5,001-page IR build: Debug 9.2 s vs ReleaseFast 0.75 s (~12×).
- `sample` shows Debug time inside `debug_allocator.captureStackTrace` /
  `StackIterator.next` (Dwarf unwinding) beneath `route_resolver.decode` /
  `toOwnedSlice`.

**Why it matters**
Anyone building Boris from source gets the slow binary. The docs' measured
claims and any CI timing inherit this. Debug mode also distorts every future
benchmark and makes the biggest measured cliff (OPT-001) look ~50× worse.

**Scale behavior**
Constant multiplier (~12–53× depending on allocation intensity), so it
compounds all other findings.

**Optimization direction**
Do not change the default `zig build` (Debug is the right developer default).
Add an explicit documented step (README/STATUS/scripts) such as
`zig build -Doptimize=ReleaseFast` for benchmarks and releases; consider a
`zig build benchmark`/`-Drelease` convenience step and CI benchmarks built
with ReleaseFast only.

**Tradeoffs / invariants**
None for correctness; keep Debug default for local dev.

**How to prove the improvement**
Time the corpus with each binary; the multiplier is already measured.

**Issue readiness:** Ready to file

---

### OPT-003 — Full-site nav in every page makes output and build time quadratic

**Classification:** Scaling risk (measured)
**Priority:** P0
**Confidence:** High
**Likely impact:** High
**Effort:** Large (design)
**Primary locus:** `themes/boris/layouts/main.html` (`{{nav}}`),
`src/html_nav.zig`, everything that reads output

**Observation**
With `{{nav}}` in the layout, every page embeds the whole site forest. Output
size grows O(n²), and every output-proportional phase (render, search, audit,
inventory, checks) inherits it.

**Evidence**
- 201 pages → 5.7 MB dist; 1,001 pages → 92 MB (≈ n²).
- Build time: 201→0.33 s, 401→1.98 s, 1,001→21.5 s (superlinear; ≈ n²).
- Validate render-only is still cheap (1,001 pages 0.23 s), so the render
  itself isn't the cliff — the output volume is, once it flows through the
  post-render stack.

**Why it matters**
This is the root scaling cliff of the default product path. It is a design
tradeoff, not a bug: the nav is genuinely served on every page.

**Scale behavior**
10k pages with this theme: ≈ 9 GB output and multi-hour builds. 100k+: not
buildable. Every theme that embeds a full-site nav has this property; the
cost multiplies because Boris re-reads the output several times.

**Optimization direction**
Theme-level options: bounded nav depth, per-section nav (children-of-ancestors
only), or a two-tier nav (collapsed siblings via CSS, no JS). Compiler-side:
make all output-proportional phases linear-in-output and cheap per byte
(OPT-001/004/031), which moves the cliff from "minutes at 5k" to "tolerable
at 100k for small navs". Document the n² output property in
`templating-and-themes.md`.

**Tradeoffs / invariants**
Nav semantics are contractual only insofar as `{{nav}}` renders the forest;
per-page output must remain deterministic and identical across `--jobs`.
Nothing in the contracts forbids a bounded-depth nav option; changing the
default theme's nav shape is a user-visible change requiring a changelog
fragment + fixture updates.

**How to prove the improvement**
Rebuild the 5k corpus with a bounded nav variant; show output MB and wall
time vs current, and confirm `dist` determinism (existing sequential/parallel
byte-equality tests).

**Issue readiness:** Needs design investigation

---

### OPT-004 — Link-audit route resolution allocates per link

**Classification:** Measured bottleneck (allocation-heavy hot path)
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium–High
**Effort:** Small
**Primary locus:** `src/route_resolver.zig` (`resolve`, `decode`),
`src/link_audit.zig` (`auditDocument`)

**Observation**
Every `href`/`src` in every published page goes through
`resolveWithinRoot` → `resolve` → `decode` (dupe + per-pass ArrayList +
`toOwnedSlice`) + segments ArrayList + output ArrayList: 4–6 allocations per
reference, even for plain relative targets like `assets/css/boris.css` or
`guides/intro.html`.

**Evidence**
- `sample` of a 401-page Debug build at t=8 s: 1885/2330 samples in
  `link_audit.auditDocument` → `route_resolver.resolveWithinRoot` →
  `route_resolver.decode` → `toOwnedSlice` → DebugAllocator stack traces.
- At 1,001 pages with a full nav there are ~1 M references per build (~1,000
  links/page); ReleaseFast still spends seconds here.

**Why it matters**
The audit runs on every build over the full output; per-link allocation
dominates its constant. Under Debug it is the single hottest spot.

**Scale behavior**
Linear in total references (≈ output bytes), i.e. O(n²) with a full-site nav;
the constant is what hurts.

**Optimization direction**
Add a no-allocation fast path in `resolve`: when the target has no `%`
escapes, no `..`/`.` segments, no trailing `/`, no leading `/`, no
query/fragment (the overwhelmingly common case for generated nav and local
links), compute the joined path into a caller stack buffer and copy once.
Keep the slow path for everything else. Preserve the exact same resolution
semantics (route_resolver has unit tests to lock this).

**Tradeoffs / invariants**
Resolution semantics and escape/`..` failure modes are tested and
contractual; the fast path must produce byte-identical results. Do not skip
the audit (it is the publication gate).

**How to prove the improvement**
Existing `route_resolver` unit tests + a before/after timing of the 1,001-page
build; optionally a counter of fast-path hits (OPT-027).

**Issue readiness:** Ready to file

---

### OPT-005 — Warm incremental builds save almost nothing

**Classification:** Measured / Incremental-build opportunity
**Priority:** P1
**Confidence:** High
**Likely impact:** High (watch-mode UX and CI)
**Effort:** Medium
**Primary locus:** `src/compile.zig` (post-render phases),
`src/cache.zig`

**Observation**
`--incremental` correctly skips rendering clean pages, but every subsequent
phase (heading harvest, search, link audit, inventory, checks, claims,
touches, proof pack) still processes the full site.

**Evidence**
- 401 pages: full 1.98 s vs warm incremental 1.81 s vs 1-page-change 1.71 s.
- 1,001 pages: full 21.5 s vs warm incremental 21.7 s.

**Why it matters**
Incremental/watch is advertised for iteration; today it is a no-op
optimization on the default theme. Watch rebuilds pay full-build time per
edit.

**Scale behavior**
Warm rebuild cost stays O(output) = O(n²) with full-site nav, regardless of
dirty set.

**Optimization direction**
Three levers, independently landable: (a) OPT-001 single-read + parallel
post-render passes; (b) allow per-page granularity in the output-proportional
phases where correctness permits (search and audit must process the overlay,
but can skip nothing — their cost is volume-driven; the fix is a cheaper
constant); (c) cache the evidence derivation: when `artifacts.json`,
`checks.json`, `claims.json` are byte-identical to prior committed bytes, the
touches/proof-pack derivation could reuse prior outputs after re-verifying
bindings (must keep the "derived from exact committed bytes" property).

**Tradeoffs / invariants**
The evidence chain must always bind to the exact committed bytes; reuse must
be gated on byte-equality of all inputs, and every freshness shortcut must be
proven safe against same-size corruption (see OPT-022).

**How to prove the improvement**
Time no-op incremental before/after on 1k/5k corpora; assert evidence reports
byte-identical to the full-build reports.

**Issue readiness:** Needs measurement first (prereq: OPT-027)

---

### OPT-006 — Page sources are read 3–4× per build; reuse `SharedCompileState.source_bytes`

**Classification:** I/O opportunity / Probable optimization
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium
**Effort:** Small–Medium
**Primary locus:** `src/compile.zig` (`renderPageSlots`,
`buildSiteHeadingIndex`, `loadAndPromoteFormat`), `src/html_body.zig`

**Observation**
In one HTML build each page source is read from disk at least 3×:
(1) `loadAndPromoteFormat` (parse frontmatter), (2) `SharedCompileState.init`
(holds `source_bytes` for fingerprints — and its internal
`populateDependencyIndexFormat` re-reads every source again), (3)
`renderPageSlots` (body render), plus (4) `buildSiteHeadingIndex` re-reads
fragment-target pages.

**Evidence**
- Code: `compile.zig` `SharedCompileState.init` allocates `source_bytes` and
  then calls `pipeline.populateDependencyIndexFormat`, which loops pages and
  `readPageAlloc` again; `renderPageSlots` calls `source_io.readPageAlloc`
  although `shared.source_bytes[page_idx]` holds identical bytes.
- `buildSiteHeadingIndex` also calls `source_io.readPageAlloc` per needed
  page while `shared.source_bytes` holds the same data.

**Why it matters**
File I/O and page-buffer churn scale linearly with pages; the data is already
in memory at all three call sites.

**Scale behavior**
Constant factor (~3–4× reads); at 100k pages ≈ 300–400k file opens avoided.

**Optimization direction**
Thread the pre-read source bytes (or a slice view) from `SharedCompileState`
into `renderPageSlots`/`buildSiteHeadingIndex` when the caller has shared
state; keep the read path for the no-shared-state callers. Ownership note:
`source_bytes` are GPA-owned and live for the whole compile — the arena views
must not outlive them (they don't; render output is arena-copied).

**Tradeoffs / invariants**
Must keep identical source-bytes (a TOCTOU change between reads today would
become invisible — acceptable only if the shared state is guaranteed
current, which it is within one process run; document it).

**How to prove the improvement**
File-open counters (OPT-027) or `dtrace`/`fs_usage` before/after; verify
output byte-identity.

**Issue readiness:** Ready to file

---

### OPT-007 — `doclink.rewrite` runs twice per page; one result is discarded

**Classification:** Probable optimization
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium
**Effort:** Medium
**Primary locus:** `src/pipeline.zig` (`scanPageWithHtmlLinks`),
`src/html_body.zig` (`renderSource`), `src/doclink.zig`

**Observation**
During dependency resolution (`populateDependencyIndexFormat` →
`scanPageWithHtmlLinks`), the full body is run through `doclink.rewrite` just
to collect `reference_ids`, and the rewritten bytes are freed. The render
path then runs `doclink.rewrite` again on the same body.

**Evidence**
- `pipeline.zig`: `const rewritten = try doclink.rewrite(...); self.gpa.free(rewritten);`
  in `scanPageWithHtmlLinks`.
- `html_body.renderSource` calls `doclink.rewrite` again with the same body.

**Why it matters**
Full-body scans are the hot currency of this compiler; this is one duplicate
full-body scan + a full-body rewrite allocation per page.

**Scale behavior**
Linear in pages × body bytes; at 100k pages it is a real cost.

**Optimization direction**
Either (a) collect `reference_ids` with a scan-only API that doesn't build
the rewritten buffer, or (b) reuse the dependency-phase rewrite when the
render call site has access to it (ordering: dependency resolution runs
before render, so the rewritten body could be stored per page in shared
state). Preserve identical rewrite semantics.

**Tradeoffs / invariants**
The dependency scan currently runs even when render might be skipped
(incremental); keep that. Diagnostics and reference validation must stay
identical.

**How to prove the improvement**
Phase counters + before/after on 5k corpus; byte-identical outputs.

**Issue readiness:** Ready to file

---

### OPT-008 — Include files are re-read per including page and re-parsed repeatedly

**Classification:** I/O opportunity / Memory opportunity
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium
**Effort:** Medium
**Primary locus:** `src/include.zig` (`expandIncludes`, `bodyOfSource`,
`readSourceAlloc`), `src/compile.zig` (`SharedCompileState.init`),
`src/pipeline.zig` (`scanIncludes`)

**Observation**
An include file used by P pages is read from disk P× by
`SharedCompileState.init` (fingerprint inputs), P× again by
`populateDependencyIndexFormat` (dependency scan), and P× again by
`expandIncludes` during render (its cache is per-page). `bodyOfSource` and
`lineBaseOfSource` re-run `parser.parse` on the include bytes at every call
site.

**Evidence**
- `include.zig` `expandRecursive` caches expanded values per page only
  (`cache` is a local in `expandIncludesWithBudget`).
- `SharedCompileState.init` stores per-page include byte arrays (duplicated
  across pages).
- `bodyOfSource`/`lineBaseOfSource` call `parser.parse` each time.

**Why it matters**
Shared fragments (headers, nav includes) are the common case; per-page
duplication is pure waste and also duplicates memory.

**Scale behavior**
Total include I/O = Σ_pages (includes used by that page) — a shared include
used by all N pages costs N reads; at 100k pages that is 100k file opens for
one file.

**Optimization direction**
A build-session include cache keyed by content-root path: read once, share
the byte buffer (refcounted), and reuse the parsed body view. Keep the
per-page expansion cache for expanded output (already exists). Preserve the
no-follow/symlink-resolution policy and the expansion budget exactly.

**Tradeoffs / invariants**
Include reading has a security policy (no-follow, resolve-beneath, budgets);
caching must not bypass it. Diagnostics line mapping must stay identical.

**How to prove the improvement**
Count include opens before/after on a corpus with a shared fragment; assert
byte-identical output.

**Issue readiness:** Ready to file

---

### OPT-009 — Site-nav fingerprint material is re-hashed per page

**Classification:** Probable optimization
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium (grows with corpus)
**Effort:** Small
**Primary locus:** `src/compile.zig` (`compilePagesInner` fingerprint loop),
`src/cache.zig` (`computePageFingerprintThemeInput`), `src/html_nav.zig`
(`siteNavMaterial`)

**Observation**
Each page fingerprint SHA-256-hashes the full `site_nav_material` (all
(id,title,parent,role) records — O(pages) bytes) plus full layout bytes and
theme material. The material is identical for every page in a run.

**Evidence**
- `compile.zig`: `nav_material` = `site.site_nav_material`, passed into
  `computePageFingerprintThemeInput` per page.
- `html_nav.siteNavMaterial` serializes every node.

**Why it matters**
Total hashing = O(pages × site_nav_bytes) = O(n²) hashing per build. At 5k
pages, nav material ≈ 225 KB × 5k pages ≈ 1.1 GB SHA-256 per build (~1–3 s).

**Scale behavior**
n² hashing; at 100k pages with a 4 MB nav material = 400 GB hashed — minutes.

**Optimization direction**
Compute `hash(nav_material)` once per build and feed the 32-byte digest into
the per-page fingerprint (length-prefixed, with an explicit marker so
fingerprints change exactly once, on upgrade). Same for layout bytes and
theme material per layout (they are per-layout constants).

**Tradeoffs / invariants**
Fingerprint format version must bump (`CACHE_FORMAT_VERSION`) so old
manifests invalidate once; the digest-vs-bytes substitution is semantically
equivalent (preimage resistance of SHA-256).

**How to prove the improvement**
Benchmark 5k/20k corpus fingerprint loop before/after; verify one cold
invalidation and then stable warm fingerprints.

**Issue readiness:** Ready to file

---

### OPT-010 — Incremental manifest lookup is O(pages × entries)

**Classification:** Scaling risk
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium (large corpora)
**Effort:** Small
**Primary locus:** `src/compile.zig` (incremental freshness loop,
~lines 2380–2410)

**Observation**
For each page, the incremental check scans the entire prior manifest
(`for (pm.value.entries) |entry| { if (eql(entity_id) … ) }`).

**Evidence**
- Code path at `compile.zig` `skip_render` block.
- 5,001-page warm incremental: 25 M string compares per build (fast but
  measurable); 100k pages → 10¹⁰ compares (~minutes).

**Why it matters**
Cold-to-warm incremental and no-op watch builds pay this per page; it is the
same class of fix as `expandDirtySet` already received.

**Scale behavior**
O(n × m) with m = manifest entries ≈ n → O(n²).

**Optimization direction**
Build a `StringHashMap` from `entity_id (+ output_path + target)` → entry
once per build; per-page O(1) lookup. Determinism unaffected.

**Tradeoffs / invariants**
Duplicate entries in a foreign/corrupt manifest: keep the current
first-match-wins semantics.

**How to prove the improvement**
Time no-op incremental at 5k and 20k before/after.

**Issue readiness:** Ready to file

---

### OPT-011 — `findNodeById` linear scan in freeze sync loop (O(n²))

**Classification:** Probable optimization / Scaling risk
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium
**Effort:** Small
**Primary locus:** `src/compile.zig` (`findNodeById`,
`freezeSiteFromPageDb`)

**Observation**
After `graph.freeze` sorts nodes, the PageDb sync loop calls `findNodeById`
(a linear scan) once per page to copy role/index/parent_index back.

**Evidence**
- `freezeSiteFromPageDb`: `for (db.itemsMut()) |*p| { if (findNodeById(g.nodes, p.entity_id)) |n| { … } }`.
- Nodes are id-sorted post-freeze, so a binary search or one id→index map
  suffices.

**Why it matters**
O(n²) eql per build on every HTML/IR-compiling run. At 5k pages ≈ 25 M
compares (invisible); at 100k ≈ 10¹⁰ (minutes).

**Scale behavior**
O(n²).

**Optimization direction**
Build id→index once (graph already has `buildIdIndex`), or binary-search the
sorted slice.

**Tradeoffs / invariants**
None; result identical.

**How to prove the improvement**
Time compile at 20k/100k synthetic corpus before/after.

**Issue readiness:** Ready to file

---

### OPT-012 — Reverse dependency index built with nested loop (O(E × T))

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (large corpora)
**Effort:** Small
**Primary locus:** `src/pipeline.zig` (`freezeDependencyIndex`)

**Observation**
For each unique edge target, the code scans all edges to collect incoming
indices: `for (targets.items) |target| { for (result.edges.items) |edge| … }`.

**Evidence**
- `freezeDependencyIndex` in `pipeline.zig` (also the IR path).
- 5k pages ≈ E×T ≈ 10k×5k = 5×10⁷ compares (visible in IR timing); 100k
  pages ≈ 2×10¹⁰.

**Why it matters**
IR builds and HTML dependency expansion pay it; it is trivially linearizable.

**Scale behavior**
O(E × T), worst case O(n²).

**Optimization direction**
Single pass over edges appending into per-target lists (same shape as
`graph.buildNav` child lists), preserving sorted/deduped output semantics.

**Tradeoffs / invariants**
Output `reverseIndex` order is deterministic and asserted by tests; preserve
it.

**How to prove the improvement**
IR build time at 20k/100k before/after; compare `graph.json` reverseIndex
bytes.

**Issue readiness:** Ready to file

---

### OPT-013 — Wiki-link resolution scans all pages per link (`findPage`)

**Classification:** Scaling risk
**Priority:** P1
**Confidence:** High
**Likely impact:** Medium (link-dense corpora)
**Effort:** Small
**Primary locus:** `src/pipeline.zig` (`findPage`, `scanWiki`),
`src/wikilink.zig`

**Observation**
Every `[[entity]]` hit calls `findPage` — a linear scan of the node list.

**Evidence**
- `pipeline.zig`: `if (!findPage(self.nodes, hit.entity_id)) { … }` inside
  `scanWiki`.
- IR build of 5k pages (≈5k wiki links) is fast only because n is small.

**Why it matters**
O(links × pages); a corpus where each page links to 50 others at 100k pages
is 5×10¹¹ eql — minutes.

**Scale behavior**
O(L × N).

**Optimization direction**
Build the id set once per resolution pass (hash set) and reuse.

**Tradeoffs / invariants**
Diagnostic emission order and missing-link reporting must stay identical
(first-wins ordering).

**How to prove the improvement**
IR build at 20k link-dense corpus before/after.

**Issue readiness:** Ready to file

---

### OPT-014 — Scanner directory-cycle check is O(dirs²)

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** High
**Likely impact:** Low–Medium
**Effort:** Small
**Primary locus:** `src/scanner.zig` (`identitySeen`, `scanDirFormat`)

**Observation**
`identitySeen` linearly scans `visited_dirs` for every entered directory.

**Evidence**
- `scanner.zig`: `if (identitySeen(visited_dirs.items, fs_id)) …`.

**Why it matters**
Deep trees with many directories (10k dirs = 5×10⁷ inode compares; 100k dirs
= 5×10⁹) slow discovery on large corpora.

**Scale behavior**
O(dirs²).

**Optimization direction**
Hash set keyed by inode.

**Tradeoffs / invariants**
Cycle detection semantics unchanged; error precedence (SymlinkCycle vs
SymlinkRejected) unchanged.

**How to prove the improvement**
Scan a 20k-dir tree before/after.

**Issue readiness:** Ready to file

---

### OPT-015 — Case-collision duplicate-id check is O(n²) worst case

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** Medium
**Likely impact:** Low (rarely triggered pattern)
**Effort:** Small–Medium
**Primary locus:** `src/graph.zig` (`diagnoseDuplicateIds`)

**Observation**
For each new unique id, the code scans all prior ids (in source order) for a
case-only collision.

**Evidence**
- `graph.zig`: `while (j < pos) … pathsDifferOnlyInCase(nodes[oj].id, n.id)`.
- Worst case (all ids unique, no case collisions) is O(n²) `eqlIgnoreCase`
  calls — e.g. 100k pages ≈ 5×10⁹.

**Why it matters**
First-wins reporting order is deterministic; the scan exists to catch
case-insensitive filesystem collisions. Only a fully case-distinct corpus
hits the worst case, but that is the *common* case.

**Scale behavior**
O(n²) worst case, O(n) when collisions exist early.

**Optimization direction**
Bucket ids by a case-folded hash; compare only within a bucket (collisions
are provably rare).

**Tradeoffs / invariants**
Keep exact source_path-order first-wins reporting and the byte-exact
`EDUPLICATEID` path unchanged; keep `EINVALIDPATH` for case-only collisions.

**How to prove the improvement**
Graph validate of 100k unique-id corpus before/after.

**Issue readiness:** Needs design investigation (correctness surface)

---

### OPT-016 — Semantic-relation validation does a linear page lookup per relation

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** High
**Likely impact:** Low–Medium (relation-heavy corpora)
**Effort:** Small
**Primary locus:** `src/graph.zig` (`validateSemanticRelations`)

**Observation**
`findIndexById(nodes, relation.target)` runs per authored relation.

**Evidence**
- `graph.zig`: `if (findIndexById(nodes, relation.target) == null) …`.

**Why it matters**
O(nodes × relations). Pages with the max 128 relations over 100k pages =
1.28×10⁷ lookups × O(n) each.

**Scale behavior**
O(N × R).

**Optimization direction**
Build the id map once (as `validateTopology` already does).

**Tradeoffs / invariants**
Diagnostic order preserved (per-node, per-relation as today).

**How to prove the improvement**
Relation-dense corpus graph validation before/after.

**Issue readiness:** Ready to file

---

### OPT-017 — `rag_emit.renderRelations` is O(pages²)

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (complete RAG export at scale)
**Effort:** Small
**Primary locus:** `src/rag_emit.zig` (`renderRelations`)

**Observation**
For each page, the children section scans all pages.

**Evidence**
- `rag_emit.zig`: `for (pages) |page| { … for (pages) |child| { … } }`.

**Why it matters**
`--rag --complete` pays n² at scale (5k pages ≈ 25 M eql — currently hidden
inside a 0.69 s build; 100k pages ≈ 10¹⁰).

**Scale behavior**
O(n²).

**Optimization direction**
One child-list pass keyed by parent id (same shape as `graph.buildNav`),
then render in id order.

**Tradeoffs / invariants**
Deterministic id-ordered output must be preserved (tests assert catalog
shapes).

**How to prove the improvement**
Time `--rag --complete` at 20k/100k before/after; byte-identical
`graph/relations.md` for a fixed corpus.

**Issue readiness:** Ready to file

---

### OPT-018 — `llms.zig` child lookup is O(pages²)

**Classification:** Scaling risk
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium
**Effort:** Small
**Primary locus:** `src/llms.zig` (`findChildren`, `renderPage`)

**Observation**
`renderPage` calls `findChildren` (full linear scan) once per page.

**Evidence**
- `llms.zig`: `for (pages, 0..) |page, index| { if (!visited[index] and … parent … ) }`.

**Why it matters**
llms.txt export becomes quadratic at 100k+ pages.

**Scale behavior**
O(n²).

**Optimization direction**
Build a parent→children index once (visited[] handling is per-render; keep
the unvisited fallback).

**Tradeoffs / invariants**
Deterministic output order (visited flag order) must be preserved.

**How to prove the improvement**
Time llms export at 20k/100k before/after.

**Issue readiness:** Ready to file

---

### OPT-019 — Theme bundle re-walked and re-read per target

**Classification:** I/O opportunity
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (multi-target builds)
**Effort:** Small–Medium
**Primary locus:** `src/theme.zig` (`loadThemeBundle`), `src/compile.zig`
(`compileHtmlSiteMulti` → per-target `compilePagesInner`)

**Observation**
`compileHtmlSiteMulti` shares PageDb, frozen site, and content/include
fingerprint state across targets, but each target's `compilePagesInner`
calls `loadThemeBundle` again: full `assets/` walk, symlink checks, and
byte reads per target.

**Evidence**
- `compile.zig`: `compilePagesInner` calls `theme_mod.loadThemeBundle(io, gpa, cwd, theme_root)` inside the per-target loop.
- Layouts are cached across targets (`layout_cache`), theme bundles are not.

**Why it matters**
M targets × theme asset bytes of re-read/re-walk; content-local assets also
re-discovered per target (asset discovery scans page-sibling trees per
target).

**Scale behavior**
Linear in targets × theme size; grows with asset count.

**Optimization direction**
Load the theme bundle once into shared state (bytes are target-independent);
per-target work reduces to copying the shared asset bytes into that target's
stage (copy is required — each target owns its output tree).

**Tradeoffs / invariants**
Per-target isolation (each target must get its own copies; symlink/UTF-8
policy checks must still run — they can run once since the source tree is
the same).

**How to prove the improvement**
Multi-target timing with a theme carrying many assets before/after; verify
both targets byte-identical to single-target builds.

**Issue readiness:** Ready to file

---

### OPT-020 — Per-page temporary allocations in the coordinator fingerprint loop

**Classification:** Probable optimization (minor)
**Priority:** P3
**Confidence:** Medium
**Likely impact:** Low
**Effort:** Small
**Primary locus:** `src/compile.zig` (`compilePagesInner` fingerprint loop)

**Observation**
Each page iteration allocates `inc_views`, `wiki_bodies`, `wiki_paths`,
`inc_with_ref`, and (for relation layouts) `relation_material`.

**Evidence**
- `compile.zig` fingerprint loop, per-iteration allocs with `defer free`.

**Why it matters**
Allocator churn in the coordinator; small per-page cost, but it runs for
every page on every build.

**Scale behavior**
Linear; constant factor.

**Optimization direction**
Reuse buffers across iterations (capacity-retaining scratch), or restructure
so the fingerprint pass can be parallelized without per-page scratch.

**Tradeoffs / invariants**
None.

**How to prove the improvement**
Allocation counters; output unchanged.

**Issue readiness:** Probably not worth filing (fold into OPT-009/OPT-010
work)

---

### OPT-021 — Heading-harvest key re-hashes full source + include bytes per build

**Classification:** Probable optimization
**Priority:** P2
**Confidence:** High
**Likely impact:** Low–Medium
**Effort:** Small
**Primary locus:** `src/compile.zig` (`buildSiteHeadingIndex`,
`headingHarvestKey`), `src/cache.zig`

**Observation**
For every fragment-target page, `headingHarvestKey` SHA-256-hashes the full
source + all include bytes even on warm incremental builds.

**Evidence**
- `buildSiteHeadingIndex` computes `headingHarvestKey` per needed page before
  consulting `prior_map`.

**Why it matters**
The page's content digest already exists conceptually (the page fingerprint
hashes the same inputs); this is a second full hashing of the same bytes per
build. Only fragment-target pages pay it, but with dense wiki fragments that
can be most pages.

**Scale behavior**
Linear in fragment-target pages × bytes; a constant-factor saving.

**Optimization direction**
Reuse the per-page fingerprint (or its source+include portion) as the
harvest key, or compute the harvest key from the already-hashed fingerprint
inputs. Bump `HEADING_HARVEST_FORMAT` on change.

**Tradeoffs / invariants**
Harvest key must remain content-addressed and distinct from the render
fingerprint (input-adapter identity must stay in the key).

**How to prove the improvement**
Warm incremental timing on a fragment-dense corpus before/after; verify
Apex-skip counts unchanged.

**Issue readiness:** Ready to file

---

### OPT-022 — Incremental digest verification reads and hashes every cached output

**Classification:** I/O opportunity (deliberate-integrity tradeoff)
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (warm builds)
**Effort:** Medium
**Primary locus:** `src/compile.zig` (incremental freshness block)

**Observation**
When a page's fingerprint matches the manifest, Boris still opens the
published output and SHA-256-hashes it to confirm the recorded digest
(`readFileAlloc` + `hashBytes`), so warm no-op builds read the entire site.

**Evidence**
- `compile.zig`: `if (readFileAlloc(io, dist_dir, page.output_path, gpa)) |out_bytes| { … hashBytes(out_bytes) … }`.
- 1,001-page warm incremental reads ~92 MB and hashes it; combined with
  inventory + checks hashing, the same bytes are hashed ~3× per build.

**Why it matters**
This is the cheapest of the three redundant full-read passes to eliminate or
short-circuit, but it exists to catch same-size corruption, so it cannot
simply be deleted.

**Scale behavior**
O(output bytes) per warm build.

**Optimization direction**
Options, in increasing aggressiveness: (a) verify digest only when
`output_size` differs OR when the manifest mtime/size of the file changed
since last build; (b) rely on the post-commit checks pass for integrity and
document that incremental pre-commit verification is a defense-in-depth
layer; (c) sample-based verification. Each must be documented as a
tradeoff against same-size corruption detection.

**Tradeoffs / invariants**
This is an intentional integrity check; the report treats deleting it as a
weakening. Keep it unless a contract-level decision is made.

**How to prove the improvement**
No-op incremental timing before/after with each option; demonstrate the
corruption cases each option still catches (existing manifest-corruption
tests should be extended).

**Issue readiness:** Needs design investigation

---

### OPT-023 — `SharedCompileState` duplicates include bytes per including page

**Classification:** Memory opportunity
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (shared-fragment sites)
**Effort:** Medium
**Primary locus:** `src/compile.zig` (`SharedCompileState`)

**Observation**
`include_bytes` holds a separate copy of each include file for every page
that includes it; a header include used by all N pages is stored N times.

**Evidence**
- `SharedCompileState.init`: `include_bytes[page_idx]` filled per page via
  `readFileAlloc` per transitive include.

**Why it matters**
Memory footprint scales with pages × shared-include bytes. At 100k pages
with a 50 KB shared header: 5 GB duplicated.

**Scale behavior**
O(pages × include bytes), worst case O(n²) bytes for a site-wide include.

**Optimization direction**
Refcount a per-path include cache (same object as OPT-008); fingerprint
consumers take the shared slice.

**Tradeoffs / invariants**
Fingerprints hash bytes, so sharing the buffer changes nothing; determinism
unaffected.

**How to prove the improvement**
Measure RSS (or allocator high-water) on a shared-fragment 20k corpus
before/after.

**Issue readiness:** Needs design investigation (ownership refactor)

---

### OPT-024 — Checks/Doctor holds all page payloads in memory

**Classification:** Memory opportunity
**Priority:** P3
**Confidence:** Medium
**Likely impact:** Low
**Effort:** Medium
**Primary locus:** `src/publication_checks.zig` (`buildReport`),
`src/doctor.zig` (`TargetAnalysisBuilder`)

**Observation**
`buildReport` streams each committed artifact but `addPage` retains page
payloads; observed footprint grew to 146 MB during the 5k-page checks phase.

**Evidence**
- `sample` of 5k-page build: Physical footprint 62 MB (t=20 s) → 146 MB
  (t=60 s) inside `buildReport`.
- `publication_checks.zig`: `analysis_builder.addPage(record.path, bytes)`.

**Why it matters**
At 100k+ pages with large navs the Doctor analysis could retain gigabytes.

**Scale behavior**
O(pages × page HTML bytes).

**Optimization direction**
Confirm whether the builder needs all payloads simultaneously; if not,
stream per page. (This may already be bounded by the builder design — verify
before changing.)

**Tradeoffs / invariants**
Findings must be complete and deterministic; ownership attribution
(`matchingRange`) may need the page alive during finalization.

**How to prove the improvement**
RSS measurement on 5k/20k builds before/after; byte-identical checks.json.

**Issue readiness:** Needs measurement first

---

### OPT-025 — Parallelize the post-render phases

**Classification:** Parallelism opportunity
**Priority:** P1
**Confidence:** Medium
**Likely impact:** High (on the dominant cost)
**Effort:** Medium–Large
**Primary locus:** `src/compile.zig` post-render section,
`src/link_audit.zig`, `src/search_index.zig`, `src/publication_checks.zig`

**Observation**
`--jobs` parallelizes only rendering (≈5 % of a 1k build). The phases that
dominate are serial per-page loops. Each phase's per-page work is
independent (page N's search extraction, link audit, doctor analysis don't
depend on page M's results), so deterministic aggregation is achievable.

**Evidence**
- Measured: jobs=4 ≈ jobs=1 (1.81 s vs 1.98 s at 401 pages) because render is
  a small fraction.
- Sampling: checks `buildReport` per-record loop is the hot serial loop.

**Why it matters**
The dominant cost could drop by ~core count on multi-core hosts while keeping
byte-identical outputs.

**Scale behavior**
Amdahl's law: serial fraction today ≈ 95 %+; parallelizing the dominant
phase converts wall time toward max(render, single-phase/core-count).

**Optimization direction**
For each phase, split the page array across workers with per-page results
collected and merged in canonical (path-sorted) order. The existing
`ParallelContext` pattern (mutex + next_page_index + shared_error) is the
proven in-repo template. Determinism requirement: merge findings by
(path, offset) order as today.

**Tradeoffs / invariants**
Deterministic output order across `--jobs` values is asserted by existing
tests — any parallel phase must preserve it. The evidence chain (checks after
commit, etc.) must stay ordered. Memory: per-worker scratch must be bounded
(see OPT-023/024).

**How to prove the improvement**
`--jobs=1` vs `--jobs=8` full builds at 1k/5k; existing byte-equality tests
across job counts.

**Issue readiness:** Needs design investigation (part of OPT-001)

---

### OPT-026 — Multi-target builds repeat content-asset discovery per target

**Classification:** I/O opportunity
**Priority:** P3
**Confidence:** Medium
**Likely impact:** Low–Medium
**Effort:** Medium
**Primary locus:** `src/content_asset.zig` (`loadSiteAssets`),
`src/compile.zig` (`compilePagesInner` per-target)

**Observation**
`loadSiteAssets` (discovery + reads + SVG policy) runs once per target, and
`collectOutputPaths`/collision checks run per target.

**Evidence**
- `compile.zig`: `content_asset.loadSiteAssets(io, gpa, content_dir, …)` inside `compilePagesInner`.

**Why it matters**
Same source tree, M targets → M× discovery + reads. (The copy into each
target's stage is required; the discovery is not.)

**Scale behavior**
Linear in targets.

**Optimization direction**
Share discovered asset state across targets (same pattern as OPT-019).

**Tradeoffs / invariants**
Per-target collision checks against that target's page outputs still run per
target (they must).

**How to prove the improvement**
Multi-target timing with page-sibling asset trees before/after.

**Issue readiness:** Probably not worth filing standalone (fold into
OPT-019)

---

### OPT-027 — Add phase timing / counters instrumentation

**Classification:** Observability prerequisite
**Priority:** P0
**Confidence:** High
**Likely impact:** High (enables everything else)
**Effort:** Small–Medium
**Primary locus:** `src/compile.zig`, `src/pipeline.zig`, `src/cli.zig`

**Observation**
Boris has no built-in phase timing, counters (file opens, reads, hashes,
renders), or `--timings` surface. Every claim in this audit required
external `sample` profiling and a hand-built corpus.

**Evidence**
- No timers/counters exist in the pipeline or compile modules (search of the
  codebase finds none).
- This audit's 100 %-sampling data had to be produced with macOS `sample`.

**Why it matters**
Without measurement, no optimization candidate can be triaged with evidence,
and regressions (e.g., an accidental O(n²)) cannot be caught.

**Optimization direction**
Add a `--timings` (or `--verbose-phases`) option emitting deterministic,
machine-readable phase durations + counters (scan, parse, graph validate,
dependency resolve, fingerprint, render, heading harvest, search, link audit,
inventory, checks, claims, touches, proof pack; counters: page reads, include
reads, hash bytes, link resolutions, fast-path hits). Keep it off the default
output path so existing stdout contracts are untouched.

**Tradeoffs / invariants**
Must not change artifacts, diagnostics, or exit codes; `--quiet` behavior
unchanged.

**How to prove the improvement**
The instrumented output itself becomes the evidence.

**Issue readiness:** Ready to file

---

### OPT-028 — Benchmark corpus generator + CI performance regression gate

**Classification:** Observability prerequisite
**Priority:** P1
**Confidence:** High
**Likely impact:** High
**Effort:** Medium
**Primary locus:** `test/`, `scripts/`, `.github/workflows/ci.yml`

**Observation**
No Boris-level benchmark exists (only vendored Apex benchmarks). The opt-in
scale smoke (`zig build test-scale-smoke`) is 200 pages with a content-only
layout and no timing assertions.

**Evidence**
- Glob for `*bench*` finds only `vendor/apex-markdown/tests/*`.
- `src/incremental_scale_smoke_test.zig` uses `<html><body>{{content}}</body></html>`.

**Why it matters**
The measured cliffs (OPT-001/003/005) can silently regress or improve with no
gate.

**Optimization direction**
Add a checked-in corpus generator (deterministic, like the existing fixture
generator pattern under `tools/testdata-generator`) producing 1k/5k page
trees with a nav layout; add a `zig build benchmark` step (ReleaseFast-only)
printing phase timings; add a CI job that fails on a threshold regression
(e.g., >2× baseline) with the corpus pinned.

**Tradeoffs / invariants**
CI budget: keep it ReleaseFast and bounded (5k pages currently ~20 s+ in the
worst case; start at 1k pages and grow after OPT-001 lands).

**How to prove the improvement**
The gate catches the 21.5 s (1k pages) baseline and prevents regressions.

**Issue readiness:** Ready to file

---

### OPT-029 — Scale smoke test should use a nav layout and assert phase behavior

**Classification:** Build/test feedback opportunity
**Priority:** P2
**Confidence:** High
**Likely impact:** Medium (test coverage of the real cliff)
**Effort:** Small
**Primary locus:** `src/incremental_scale_smoke_test.zig`

**Observation**
The existing 200-page incremental smoke uses a `{{content}}`-only layout, so
it never exercises nav rendering, the O(n²) output path, or the post-render
phases at scale.

**Evidence**
- `incremental_scale_smoke_test.zig`: layout string is
  `<html><body>{{content}}</body></html>`.

**Why it matters**
The project's only scale test validates the wrong shape; the measured
bottlenecks are invisible to it.

**Optimization direction**
Add a second smoke (or extend the existing one) with the real
`themes/boris/layouts/main.html`, asserting completion and deterministic
output at ~1k pages, plus a generous wall-time budget that catches quadratic
regressions without being flaky.

**Tradeoffs / invariants**
Keep it opt-in (not part of `zig build test`) per the existing decision;
ReleaseFast-only to keep it fast.

**How to prove the improvement**
The smoke fails on the current tree's 1k-page timing before OPT-001/003 and
passes after.

**Issue readiness:** Ready to file

---

### OPT-030 — Document and standardize ReleaseFast builds for benchmarks/releases

**Classification:** Build/test feedback opportunity
**Priority:** P3
**Confidence:** High
**Likely impact:** Low
**Effort:** Small
**Primary locus:** `README.md`, `docs/STATUS.md`, `scripts/release-gate.sh`,
`build.zig`

**Observation**
Nothing in the docs tells users/CI that `zig build` (Debug) is ~12–53× slower
than ReleaseFast on the HTML path, and the release gate does not build a
ReleaseFast binary.

**Evidence**
- Measured Debug vs ReleaseFast (see OPT-002).

**Why it matters**
Release validation and user benchmarks measure the slow binary by default.

**Optimization direction**
Document `zig build -Doptimize=ReleaseFast` for benchmarks; add an optional
`-Drelease` step or a release-gate check that builds/tests ReleaseFast.

**Tradeoffs / invariants**
None.

**How to prove the improvement**
Release-gate timing before/after.

**Issue readiness:** Ready to file

---

### OPT-031 — Single shared read pass over the overlay for search/audit/inventory

**Classification:** Cross-cutting I/O opportunity
**Priority:** P2
**Confidence:** Medium
**Likely impact:** Medium–High
**Effort:** Medium–Large
**Primary locus:** `src/compile.zig` post-render section,
`src/search_index.zig`, `src/link_audit.zig`, `src/artifact_inventory.zig`

**Observation**
Search (`writeOverlay`), link audit (`audit`), and inventory (`collect`) each
independently open and read the same published pages from the staged/live
overlay; the checks phase then reads them a fourth time.

**Evidence**
- Each phase has its own `readOverlayFile`/`readFileAlloc` loop over
  `page_paths` (search_index.zig:296, link_audit.zig audit, artifact_inventory collect).

**Why it matters**
Four full-tree reads of the same bytes per build; with 92 MB output that is
≈370 MB of reads, most of which could be one pass.

**Scale behavior**
Linear in output bytes per phase; total constant ≈ 4×.

**Optimization direction**
Produce a per-page byte buffer array from the overlay once (bounded: hold
one page at a time in a streaming worker chain, or hold the array with a
documented memory bound), then feed search, audit, and inventory consumers.
Checks must still read committed bytes post-commit (OPT-001).

**Tradeoffs / invariants**
Overlay semantics (staged wins, live fallback) and missing-page failures
must be preserved exactly; memory bound must be explicit.

**How to prove the improvement**
Phase timers + file-read counters on 1k/5k corpora.

**Issue readiness:** Needs design investigation (prereq: OPT-027)

---

### OPT-032 — Watch-mode full-tree re-poll cost

**Classification:** I/O opportunity
**Priority:** P3
**Confidence:** Medium
**Likely impact:** Low–Medium (large trees)
**Effort:** Small
**Primary locus:** `src/watch.zig` (`PollingWatcher.scanFiles`, `idle_poll_ms`)

**Observation**
`PollingWatcher` re-walks and stats every file under every watched root
every 500 ms while idle.

**Evidence**
- `watch.zig`: `scanFiles` (full recursive walk + `statFile` per file) runs
  per poll in `poll`.

**Why it matters**
At 100k files, 100k stats per 500 ms is sustained I/O; on battery/CI hosts
this is wasteful. (The poll interval is already documented as a deliberate
portable design.)

**Scale behavior**
O(files) per poll.

**Optimization direction**
Adaptive idle interval (back off to 1–2 s on large trees), or stat-batching;
do not add platform-specific notification backends without policy review
(the project deliberately chose portable polling).

**Tradeoffs / invariants**
Change-detection latency is contractual-ish (watch mode contract); keep
mtime+size semantics.

**How to prove the improvement**
CPU%/syscall counters while idle on a large tree before/after.

**Issue readiness:** Probably not worth filing (minor; fold into watch UX
work)

---

### OPT-033 — Repeated failed include opens are not cached

**Classification:** Probable optimization (diagnostic/failure path)
**Priority:** P3
**Confidence:** Medium
**Likely impact:** Low
**Effort:** Small
**Primary locus:** `src/pipeline.zig` (`scanIncludes`)

**Observation**
When an include target is missing, the diagnostic is emitted per including
page but the path is never recorded as "already failed", so a missing shared
fragment is re-opened (and fails) once per page.

**Evidence**
- `scanIncludes`: `if (self.scanned_sources.contains(hit.path)) continue;`
  is only populated on success (`scanned_sources.put` after a successful
  read).

**Why it matters**
Failure-path I/O amplification for a corpus with one broken shared include:
N page-opens that all fail identically.

**Scale behavior**
O(pages × missing includes).

**Optimization direction**
Record failed paths in a separate set (or record all paths, successful or
not) while still emitting the diagnostic once per distinct locus.

**Tradeoffs / invariants**
Diagnostic emission must stay identical (per-page locus is current
behavior).

**How to prove the improvement**
Corrupt a shared include; count opens before/after.

**Issue readiness:** Probably not worth filing (low value)

---

### OPT-034 — `graph.json`/IR output size at scale

**Classification:** Scaling risk (output size)
**Priority:** P3
**Confidence:** High
**Likely impact:** Low (schema-bound)
**Effort:** Large
**Primary locus:** `src/ir_emit.zig` (`renderGraph`), `src/pipeline.zig`

**Observation**
`graph.json` embeds nodes + edges + reverseIndex + nav; measured 6.3 MB at
5k pages ≈ 1.3 KB/page.

**Evidence**
- `/tmp/boris-audit/.boris/graph.json` = 6,330,063 bytes for 5,001 pages.

**Why it matters**
At 100k pages ≈ 130 MB, at 1 M ≈ 1.3 GB — mostly reverseIndex duplication of
edge data. The IR schema is a published contract; changing it requires a
schema bump.

**Scale behavior**
Linear per page with a large constant; reverseIndex duplicates edge
information.

**Optimization direction**
Nothing to change now; document the size projection in `json-ir-and-manifest.md`
and revisit reverseIndex encoding if 1 M-page IR becomes a real use case.

**Tradeoffs / invariants**
Schema-versioned contract; no change without bump + contract update.

**How to prove the improvement**
N/A (documentation/decision item).

**Issue readiness:** Probably not worth filing (note only)

---

### OPT-035 — `proof-pack.json`/`touches.json`/`index.html` size at scale

**Classification:** Scaling risk (output size)
**Priority:** P3
**Confidence:** High
**Likely impact:** Low
**Effort:** Large
**Primary locus:** `src/publication_proof_pack.zig`,
`src/publication_touches.zig`

**Observation**
`proof-pack.json` (1.3 MB at 1k pages) embeds the full artifact records and
page-id relationships; `touches.json` (0.98 MB) and `index.html` (1.1 MB)
grow linearly with per-page records.

**Evidence**
- Measured at 1k pages: artifacts.json 300 KB, touches.json 976 KB,
  proof-pack.json 1.31 MB, index.html 1.17 MB.

**Why it matters**
At 100k pages these become ~100 MB–130 MB each. The self-contained
presentation model is deliberate ("strict four-report binding", embedded
model digest), so this is an intentional size tradeoff to document rather
than optimize away.

**Scale behavior**
Linear per page.

**Optimization direction**
Document the size projection in `publication-proof-pack.md`/
`publication-touches.md`; only revisit (e.g., digest-referenced artifacts in
the pack) with an explicit schema decision.

**Tradeoffs / invariants**
The binding model requires the pack to be self-contained; changing it is a
contract change.

**How to prove the improvement**
N/A (documentation/decision item).

**Issue readiness:** Probably not worth filing (note only)

---

## Cross-cutting opportunities

These are the ones that remove work across several modules at once; each is
also listed above as a candidate but is called out here because fixing it
helps multiple subsystems.

1. **A single "read the published page once" overlay pass** (OPT-001, OPT-031).
   Today search, link audit, inventory, and checks each re-read the same
   bytes; the incremental digest check (OPT-022) adds another pass. One
   bounded read-once pipeline with per-consumer streaming shrinks total
   output I/O from ~4–5 full-tree reads to 1–2 and is the prerequisite for
   the parallelization win (OPT-025).
2. **Pre-digested constant fingerprint inputs** (OPT-009, OPT-021). The site
   nav material, layout bytes, and theme material are constants per build;
   hashing them once and mixing 32-byte digests into per-page fingerprints
   turns O(n²) hashing into O(n).
3. **Shared immutable derived graph state** (OPT-011, OPT-012, OPT-013,
   OPT-016). Id→index maps, child lists, and reverse adjacency are built
   several times in different shapes across `graph.zig`, `pipeline.zig`, and
   `compile.zig`; a single frozen "graph index" (id map + child lists +
   reverse edges) built once after freeze and reused by dependency
   resolution, nav, fingerprints, projections (llms/RAG), and incremental
   expansion would delete the four separate O(n²) paths.
4. **Build-session include cache** (OPT-008, OPT-023). One read + one parsed
   body view per include path, shared across dependency scan, fingerprint
   inputs, and render expansion, fixes both the I/O duplication and the
   memory duplication.
5. **Phase instrumentation + a ReleaseFast benchmark gate** (OPT-027,
   OPT-028, OPT-030) turn every future optimization from guesswork into a
   measured landing, and make the existing audit culture (Boris's evidence
   discipline) apply to performance claims.

---

## Scaling cliffs

Ranked by how much they hurt at each size. "Today" = ReleaseFast, default
theme, measured where noted.

| # | Cliff | Mechanism | 10k pages | 100k pages | 1M pages |
|---|---|---|---|---|---|
| 1 | Full-site nav output (OPT-003) | Every page embeds O(n) nav → O(n²) output bytes; all post-render phases read it | ~0.9 GB output; ~30+ min build | ~90 GB output; not buildable | n/a |
| 2 | Post-render verification stack (OPT-001) | 4–5 full-tree read/hash/parse passes, serial | ~5–10 min | hours | n/a |
| 3 | Incremental warm rebuild (OPT-005) | All output-proportional phases run regardless of dirty set | ~full-build time per edit | unusable watch | n/a |
| 4 | O(n²) index/scan algorithms | OPT-010 (manifest), OPT-011 (findNodeById), OPT-013 (findPage), OPT-012 (reverse index) | seconds–tens of seconds | minutes | hours |
| 5 | Projection O(n²): llms/rag relations (OPT-017/018) | Linear child scans per page | seconds | minutes | hours |
| 6 | Scanner dir-cycle check (OPT-014) + case-collision (OPT-015) | O(dirs²)/O(n²) scans | seconds | minutes | n/a |
| 7 | IR/proof-pack output size (OPT-034/035) | ~1.3 KB/page records | ~13 MB / ~13 MB | ~130 MB each | ~1.3 GB each |
| 8 | Watch polling (OPT-032) | Full-tree stat every 500 ms | 10k stats/s | 200k stats/s | not viable |
| 9 | Debug default build (OPT-002) | ~12–53× multiplier on everything | 30–50× of the above | n/a | n/a |

Notes: Boris may not need to support 1 M-page IR/HTML today; the purpose of
this table is to show which algorithms *become* ugly and which are simply
large-but-linear. Items 4–6 are cheap to fix now (hash maps / one-pass
adjacency) and should be fixed before scale claims are made. Items 1–3 are
the structural ones that need design work (theme nav shape + single-pass
overlay + parallelization).

---

## Things that look inefficient but should remain

The audit's rules require calling out apparent inefficiencies that are
actually intentional costs of Boris's guarantees. Verified cases:

1. **Checks re-hash and re-parse every committed artifact**
   (`publication_checks.buildReport`). This is the publication evidence
   model: the checks layer independently verifies the committed bytes and
   renders Doctor findings over the committed tree. Weakening it (sampling,
   trusting producer digests, skipping Doctor) would hollow out the
   ARTIFACT_DIGEST / rendered-content claims the whole publication stack is
   built to substantiate. It must run on the committed tree, so it cannot
   reuse pre-commit buffers without a proof. Optimize its *constant*
   (parallelism, cheaper per-byte parse) but not its coverage.

2. **Artifact inventory computes its own per-file digests**
   (`artifact_inventory.collect`). The inventory is the producer-authoritative
   record of what the build committed; its sha256 values are the ground truth
   the checks layer verifies against. It cannot "reuse" a digest from the
   fingerprint layer, because the fingerprint inputs (source bytes) are not
   the committed artifact bytes (rendered HTML).

3. **The evidence chain re-reads artifacts/checks/claims per layer** (claims
   reads artifacts + checks; touches reads artifacts + checks + claims;
   proof pack reads all four). This is the "derived from the exact committed
   bytes" contract — each layer must bind to what the previous layer actually
   wrote. The design is already efficient in the right way: the layers read
   the *small evidence reports*, not the tree. Do not "optimize" by passing
   in-memory state between layers.

4. **Incremental digest verification of cached outputs** (OPT-022). The
   pre-commit freshness check catches same-size corruption of published HTML
   before a watch/incremental run reuses it. Any removal is a weakening;
   treat as a documented tradeoff, not a bug.

5. **Per-page graph chrome rendering (`renderNav` per page)**. Every page
   genuinely serves the full nav; the output is the product. The correct
   optimization is not to skip the render but to make the phases linear in
   that (large) output and to offer theme authors a bounded-nav option.

6. **`validate` renders every page fully** (`validatePrepublicationTarget`).
   Validation's contract is that a passing `validate` proves the same
   source/config would compile; skipping render would let Apex/component
   failures through. It is the intended cost (and is cheap: 0.23 s / 1k
   pages).

7. **The default Debug build**. Debug is the correct local-development
   default (safety, diagnostics); the fix is guidance/benchmarking (OPT-002),
   not shipping a different default.

8. **Full-tree stale-cleanup walk on non-incremental builds**. The walk only
   runs when there is no incremental manifest and is required to prune
   removed pages deterministically.

---

## Measurement gaps

Questions that currently cannot be answered without new instrumentation or
fixtures:

1. **Phase-by-phase wall time** of a default HTML build (scan, parse, graph,
   dependency resolve, fingerprint, render, heading harvest, search, audit,
   inventory, checks, claims, touches, proof). This audit inferred the split
   from `sample` profiles and the validate-vs-build delta; a `--timings`
   option (OPT-027) is the prerequisite for triaging most candidates.
2. **Read/hash byte counters** (page opens, include opens, bytes hashed per
   phase) — needed to verify OPT-006/008/022/031.
3. **Allocation counts** per phase (e.g., link resolutions in the audit;
   fingerprint-loop scratch) — needed to size OPT-004/020.
4. **Warm vs cold incremental** at 5k+ pages with nav layouts — the existing
   smoke (200 pages, content-only layout) does not cover it (OPT-029).
5. **Multi-target scaling** with realistic themes and assets — theme/content
   asset reuse (OPT-019/026) has no fixture with real asset trees.
6. **Watch-mode idle cost** on large trees — no automated measurement exists
   (OPT-032).
7. **Memory high-water** across phases — the checks-phase footprint (146 MB
   at 5k) is the only observation; a `--max-rss`/allocator counter would
   ground OPT-023/024.
8. **Debug vs ReleaseFast multipliers** across the full test suite — only the
   HTML/IR paths were measured here.

These gaps are themselves candidates: OPT-027 (instrumentation) and OPT-028
(benchmark gate) are the two "measurement infrastructure" issues.

---

## Suggested issue batches

Ordered so each wave is independently landable and reviewable; dependencies
are called out.

**Wave 0 — measurement infrastructure (prerequisite for honest triage)**
- OPT-027 phase timers/counters (`--timings`)
- OPT-028 benchmark corpus generator + ReleaseFast CI gate (start at 1k pages)
- OPT-030 document ReleaseFast for benchmarks

**Wave 1 — low-risk wins (no behavior change, small diffs)**
- OPT-009 pre-hash constant fingerprint inputs (bump cache format once)
- OPT-010 manifest lookup index
- OPT-011 `findNodeById` map/binary search
- OPT-012 reverse-index single pass
- OPT-013 wiki-link id set
- OPT-014 scanner inode set
- OPT-016 relation validation id map
- OPT-017 / OPT-018 llms + rag-relations child-list passes
- OPT-021 harvest-key reuse
- OPT-004 link-audit allocation-free fast path (guarded by route_resolver
  tests)

**Wave 2 — I/O and memory**
- OPT-006 reuse `shared.source_bytes` in render/heading paths
- OPT-008 + OPT-023 build-session include cache (read once, refcounted)
- OPT-007 drop the discarded doclink rewrite
- OPT-019 theme bundle shared across targets (+ OPT-026 content assets)
- OPT-033 failure-path include cache (optional)

**Wave 3 — incremental compilation**
- OPT-022 incremental digest verification options (documented tradeoff)
- OPT-005 evidence-derivation reuse on byte-identical inputs
- Extend the scale smoke to nav layouts (OPT-029)

**Wave 4 — large-corpus scaling / parallel rendering**
- OPT-001 + OPT-031 single-read overlay pass with per-consumer streaming
- OPT-025 parallelize search/audit/checks per-page work (deterministic merge)
- OPT-003 nav-depth/theme options for the output cliff

**Wave 5 — developer feedback speed**
- OPT-002 (already P0) is build guidance, not a code change
- Test throughput: the ~8.8× suite duplication is structural (documented in
  `docs/audits/test-throughput-audit.md`); only worth a card if maintainers
  accept test-file reorganization

Dependencies: Waves 1–2 are independent of Wave 0 but benefit from its
before/after numbers. Wave 4 depends on OPT-027 for verification and is
easier after Waves 1–2 (less noise). OPT-003's design work should not block
Wave 4 — the overlay/pipeline work helps regardless of nav shape.

---

## Top 25

| Rank | ID | Title | Impact | Effort | Confidence | Why now |
|---:|---|---|---|---|---|---|
| 1 | OPT-001 | Post-render publication/verification stack dominates HTML builds | High | Medium | High | Measured 98 % of wall time; the default CLI path |
| 2 | OPT-027 | Phase timing / counters instrumentation | High | Small–Med | High | No measurement exists; gates every other candidate |
| 3 | OPT-003 | Full-site nav ⇒ O(n²) output ⇒ superlinear builds | High | Large | High | Root scaling cliff; 5k pages already >10 min |
| 4 | OPT-002 | Default Debug build is 12–53× slower | High | Small | High | Every user/benchmark pays it; trivial to fix docs/CI |
| 5 | OPT-004 | Link-audit per-link allocation | Medium–High | Small | High | Profile-confirmed hot spot; cheap fast path |
| 6 | OPT-005 | Warm incremental builds save ~nothing | High | Medium | High | Watch mode advertises incremental; measured no-op |
| 7 | OPT-025 | Parallelize post-render phases | High | Med–Large | Medium | Converts the dominant cost toward core-count scaling |
| 8 | OPT-009 | Pre-hash constant fingerprint inputs | Medium | Small | High | O(n²) hashing today; trivial fix |
| 9 | OPT-006 | Reuse pre-read source bytes in render/heading | Medium | Small–Med | High | 3–4× redundant page reads; data already in memory |
| 10 | OPT-031 | Single-read overlay pass (search/audit/inventory) | Medium–High | Med–Large | Medium | 4× redundant full-tree reads; compounds OPT-001 |
| 11 | OPT-008 | Include cache across pages | Medium | Medium | High | Shared fragments are the norm; I/O + memory |
| 12 | OPT-010 | Manifest lookup O(n×entries) | Medium | Small | High | Same class as the already-fixed `expandDirtySet` |
| 13 | OPT-011 | `findNodeById` O(n²) in freeze sync | Medium | Small | High | Every compile run pays it |
| 14 | OPT-013 | Wiki-link resolution O(L×N) | Medium | Small | High | Link-dense corpora at 100k |
| 15 | OPT-007 | Doclink rewrite done twice, one discarded | Medium | Medium | High | Duplicate full-body scan per page |
| 16 | OPT-012 | Reverse-index O(E×T) | Medium | Small | High | IR builds; trivially linearizable |
| 17 | OPT-017 | `rag_emit.renderRelations` O(n²) | Medium | Small | High | Complete-RAG export cliff |
| 18 | OPT-018 | `llms.findChildren` O(n²) | Medium | Small | High | llms.txt export cliff |
| 19 | OPT-022 | Incremental digest verification reads whole output | Medium | Medium | High | Warm-build I/O; needs explicit tradeoff decision |
| 20 | OPT-028 | Benchmark corpus + CI regression gate | High | Medium | High | Prevents the cliffs from regressing silently |
| 21 | OPT-019 | Theme bundle re-walked per target | Medium | Small–Med | High | Multi-target duplication |
| 22 | OPT-023 | SharedCompileState duplicates include bytes | Medium | Medium | High | Memory cliff on shared-fragment sites |
| 23 | OPT-016 | Semantic-relation validation O(N×R) | Low–Med | Small | High | Relation-heavy corpora |
| 24 | OPT-029 | Scale smoke with nav layout + timing | Medium | Small | High | Only scale test covers the wrong shape |
| 25 | OPT-014 | Scanner dir-cycle check O(dirs²) | Low–Med | Small | High | Deep trees at 100k dirs |

---

## Appendix — minor items not worth individual cards

- `theme.zig assetBytes` linear lookup — bounded by asset count and call
  frequency; fold into OPT-019 if touched.
- `content_asset` per-build validation rewrite in the fingerprint loop is a
  deliberate fail-loud check (validates images every build even when cached);
  keep, but it re-scans the body — can share the render-path scan once the
  single-pass work lands.
- `rss_date`/`rss` sorting is bounded (limit 500); fine.
- `countLinesUpTo`/`sourceLineAt`/`frontmatterLineBase` re-count newlines per
  call — linear in prefix, called a handful of times per file; fine.
- `html_nav.renderNav` per-node `relativeHref` allocations are per-output
  byte; inherent to the nav output size.
- `appendFmt` in `main.zig` allocates per format call — only on report
  rendering paths; fine.
- `dependency.addDependency` dedup scans are O(degree) but inputs are already
  deduped upstream; fine.
- `publication_checks` per-finding `formatText` allocations — only on
  failure paths; acceptable (bounded by finding count), but see the 4,900-
  finding failure case in diagnostics (consider capping printed findings or
  summarizing, while keeping the full JSON report).
