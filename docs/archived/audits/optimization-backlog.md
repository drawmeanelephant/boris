> **Archived 2026-08-21 — issue [#693](https://github.com/drawmeanelephant/boris/issues/693).**
> This file was moved from `docs/audits/optimization-backlog.md` to `docs/archived/audits/optimization-backlog.md`
> as a historical record. Do not load this file as standing agent context. Git history preserves the original.

# Boris Optimization Backlog (triage of `optimization-audit.md`)

Status: triage backlog, 2026-08-11
Source: `docs/audits/optimization-audit.md` (audit date 2026-08-11, revision
`feature/rag-working-context-packs`)
Purpose: convert the audit's candidate list into concrete, independently
implementable GitHub issues with labels, priorities, dependencies, and
acceptance criteria. This document is the triage artifact; the audit report
remains the evidence source for every claim repeated here.

## How to use this backlog

- Every audit candidate `OPT-NNN` becomes one GitHub issue `PERF-NNN` (IDs
  kept identical so the audit and backlog cross-reference 1:1).
- Each issue below lists: **labels**, **priority**, **status** (issue
  readiness, carried over from the audit), **depends on**, and **acceptance
  criteria** (what a PR must demonstrate, including how to measure).
- Wave batches at the end are the recommended landing order; every wave is
  independently landable.
- Issues marked **Probably not worth filing** in the audit are *not* filed;
  they are recorded in the master table with a "fold into / note" disposition
  so the triage is complete and auditable.

## Executive summary of the triage

- **4 P0 issues.** Three are product/measurement work: the post-render
  verification stack (the measured >99 % of default HTML build wall time),
  phase-timing instrumentation (prerequisite for honest before/after
  numbers), the quadratic full-site-nav output cliff, and one is a docs/CI
  guidance fix (Debug vs ReleaseFast builds).
- **13 P1 issues**, 10 of them ready-to-file low-risk wins (hash-map/index
  fixes and one allocation-free fast path), plus incremental-build savings,
  redundant source reads, and the benchmark gate.
- **Two dependency chains dominate.** `PERF-027` (timers) gates honest
  measurement of most candidates; `PERF-001` (single-read overlay +
  post-render stack) gates `PERF-005`, `PERF-025`, and `PERF-031`. Wave 0 is
  the measurement infrastructure; Wave 1 is the independent O(n²)→O(n) fixes
  that need no measurement to be safe.
- **Nothing is blocked on a design decision** except the intentional-cost
  tradeoffs: `PERF-003` (nav shape), `PERF-022` (digest verification
  weakening), `PERF-023` (ownership refactor), `PERF-025` (parallel merge
  design), and `PERF-015` (case-collision correctness surface).
- **Do-not-file dispositions:** `PERF-020` (fold into 009/010), `PERF-026`
  (fold into 019), `PERF-032` (fold into watch UX), `PERF-033` (low value),
  `PERF-034`, `PERF-035` (schema-bound documentation notes). The audit's
  "Things that look inefficient but should remain" section lists the
  intentional costs that must NOT be filed as optimizations (checks
  re-hash/parse, inventory digests, evidence-chain re-reads, incremental
  digest verification, full validate rendering, Debug default).

## Issue conventions

| Field | Convention |
|---|---|
| ID | `PERF-NNN` (mirrors `OPT-NNN`) |
| Labels | `perf`, `optimization` + one each of: `priority/p0…p3`, `classification/<audit class>`, `impact/<high\|med\|low>`, `effort/<small\|med\|large>`, `status/<ready\|needs-measurement\|needs-design\|note>`, plus `good-first-issue` where effort=Small and no design surface |
| Milestone | Wave number from the batches section |
| Acceptance | Concrete, measurable; references the synthetic corpus procedure from the audit (`/tmp/boris-audit`, 5,001 pages, ReleaseFast) unless stated otherwise |

## Master table (all 35 candidates)

| ID | Title | Pri | Class | Impact | Effort | Confidence | Status | Depends on |
|---|---|---|---|---|---|---|---|---|
| PERF-001 | Post-render publication/verification stack dominates HTML builds | P0 | Measured bottleneck | High | Medium | High | Ready to file | PERF-027 (prereq measurement) |
| PERF-002 | Default Debug build is 12–53× slower | P0 | Measured / build feedback | High | Small | High | Ready to file | — |
| PERF-003 | Full-site nav ⇒ O(n²) output | P0 | Scaling risk (measured) | High | Large | High | Needs design investigation | PERF-027, PERF-001 (verification) |
| PERF-004 | Link-audit per-link allocation | P1 | Measured bottleneck | Med–High | Small | High | Ready to file | — |
| PERF-005 | Warm incremental builds save ~nothing | P1 | Measured / incremental | High | Medium | High | Needs measurement first | PERF-027, PERF-001 |
| PERF-006 | Page sources read 3–4× per build | P1 | I/O / probable | Medium | Small–Med | High | Ready to file | — |
| PERF-007 | Doclink rewrite runs twice; one discarded | P1 | Probable | Medium | Medium | High | Ready to file | — |
| PERF-008 | Include files re-read per page + re-parsed | P1 | I/O / memory | Medium | Medium | High | Ready to file | — |
| PERF-009 | Site-nav fingerprint material re-hashed per page | P1 | Probable | Medium | Small | High | Ready to file | cache format bump (internal) |
| PERF-010 | Incremental manifest lookup O(n×entries) | P1 | Scaling risk | Medium | Small | High | Ready to file | — |
| PERF-011 | `findNodeById` O(n²) in freeze sync | P1 | Probable / scaling | Medium | Small | High | Ready to file | — |
| PERF-013 | Wiki-link resolution O(L×N) | P1 | Scaling risk | Medium | Small | High | Ready to file | — |
| PERF-025 | Parallelize post-render phases | P1 | Parallelism | High | Med–Large | Medium | Needs design investigation | PERF-001, PERF-027 |
| PERF-028 | Benchmark corpus + CI regression gate | P1 | Observability | High | Medium | High | Ready to file | PERF-027 (phases to assert) |
| PERF-012 | Reverse-index O(E×T) | P2 | Scaling risk | Medium | Small | High | Ready to file | — |
| PERF-014 | Scanner dir-cycle check O(dirs²) | P2 | Scaling risk | Low–Med | Small | High | Ready to file | — |
| PERF-015 | Case-collision duplicate-id O(n²) | P2 | Scaling risk | Low | Small–Med | Medium | Needs design investigation | — |
| PERF-016 | Semantic-relation validation O(N×R) | P2 | Scaling risk | Low–Med | Small | High | Ready to file | — |
| PERF-017 | `rag_emit.renderRelations` O(n²) | P2 | Scaling risk | Medium | Small | High | Ready to file | — |
| PERF-018 | `llms.findChildren` O(n²) | P2 | Scaling risk | Medium | Small | High | Ready to file | — |
| PERF-019 | Theme bundle re-walked per target | P2 | I/O | Medium | Small–Med | High | Ready to file | — |
| PERF-021 | Heading-harvest key re-hashes full bytes | P2 | Probable | Low–Med | Small | High | Ready to file | heading-harvest format bump (internal) |
| PERF-022 | Incremental digest verification reads all output | P2 | I/O (intentional tradeoff) | Medium | Medium | High | Needs design investigation | explicit tradeoff decision |
| PERF-023 | SharedCompileState duplicates include bytes | P2 | Memory | Medium | Medium | High | Needs design investigation | PERF-008 (shared cache) |
| PERF-024 | Checks/Doctor holds all payloads in memory | P3 | Memory | Low | Medium | Medium | Needs measurement first | PERF-001 (may be folded) |
| PERF-029 | Scale smoke should use nav layout + timing | P2 | Build/test feedback | Medium | Small | High | Ready to file | — |
| PERF-030 | Document/standardize ReleaseFast builds | P3 | Build/test feedback | Low | Small | High | Ready to file | — |
| PERF-020 | Per-page fingerprint-loop scratch | P3 | Probable (minor) | Low | Small | Medium | Probably not worth filing | fold into PERF-009/010 |
| PERF-026 | Multi-target content-asset discovery | P3 | I/O | Low–Med | Medium | Medium | Probably not worth filing | fold into PERF-019 |
| PERF-031 | Single shared read pass over overlay | P2 | Cross-cutting I/O | Med–High | Med–Large | Medium | Needs design investigation | PERF-027 |
| PERF-032 | Watch-mode full-tree re-poll cost | P3 | I/O | Low–Med | Small | Medium | Probably not worth filing | fold into watch UX |
| PERF-033 | Failed include opens not cached | P3 | Probable (failure path) | Low | Small | Medium | Probably not worth filing | — |
| PERF-034 | `graph.json`/IR output size at scale | P3 | Scaling risk (size) | Low | Large | High | Probably not worth filing | note only, schema-bound |
| PERF-035 | proof-pack/touches/index.html size at scale | P3 | Scaling risk (size) | Low | Large | High | Probably not worth filing | note only, schema-bound |

---

## P0 issues (detailed)

### PERF-001 — Post-render publication/verification stack dominates HTML builds

**Labels:** `perf`, `optimization`, `priority/p0`, `classification/measured-bottleneck`, `impact/high`, `effort/medium`, `status/ready`
**Milestone:** Wave 4
**Depends on:** PERF-027 (phase timers must exist to prove the improvement)
**Audit reference:** OPT-001

**Problem.** After pages render (0.23 s for 1,001 pages), the build spends
~all remaining wall time in serial full-tree passes: rendered-search
extraction, output link audit, artifact inventory, publication checks
(stream + SHA-256 + Doctor HTML analysis of every page), then
claims/touches/proof-pack. Measured: 1,001-page full build 21.5 s vs
render-only validate 0.23 s; `sample` shows 98 % of samples inside
`publication_checks.buildReport` (`compile.zig:2788`, per-record loop at
line 528). A 5,001-page full build exceeded 600 s and was killed.

**Primary locus.** `src/compile.zig` post-render section (~lines 2540–2860),
`src/publication_checks.zig` (`buildReport`), `src/doctor.zig`,
`src/link_audit.zig`, `src/search_index.zig`, `src/artifact_inventory.zig`.

**Acceptance criteria**
- Phase timers (PERF-027) on the 1,001-page corpus: full build drops from
  ~21 s toward the render + single-pass floor (~1–3 s).
- `checks.json`, `claims.json`, `touches.json`, `proof-pack.json` byte-
  identical to the pre-change build; exit codes identical.
- Checks must still verify the *committed* tree (post-commit ordering kept);
  any reuse of pre-commit buffers requires proving stage == committed.

**Notes for the implementer.** The checks phase is evidence-required (see
the audit's "should remain" list); do not weaken its coverage. Options that
preserve coverage: parallelize the per-page consumers (PERF-025), and feed
the search/audit/inventory phases from a single read pass (PERF-031). The
Checks/Doctor memory question is tracked in PERF-024.

---

### PERF-002 — Default Debug build is 12–53× slower on the HTML path

**Labels:** `perf`, `optimization`, `priority/p0`, `classification/measured-bottleneck`, `classification/build-feedback`, `impact/high`, `effort/small`, `status/ready`
**Milestone:** Wave 5
**Depends on:** —
**Audit reference:** OPT-002

**Problem.** `zig build` defaults to Debug; the DebugAllocator captures a
stack trace per allocation. Measured: 401-page corpus — Debug 98.1 s vs
ReleaseFast 1.84 s (~53×); 5,001-page IR build — 9.2 s vs 0.75 s (~12×).
Docs' measured claims and CI timings inherit the slow binary, and Debug
distorts every future benchmark (it makes PERF-001 look ~50× worse).

**Primary locus.** `build.zig` (default `optimize`), `README.md`,
`docs/STATUS.md`, `scripts/release-gate.sh`.

**Acceptance criteria**
- README/STATUS document `zig build -Doptimize=ReleaseFast` for benchmarks
  and release builds; release gate (or a convenience `zig build benchmark`
  step) builds ReleaseFast.
- Default `zig build` stays Debug (it is the right developer default — do
  not change it).
- No product code change required.

---

### PERF-003 — Full-site nav in every page makes output and build time quadratic

**Labels:** `perf`, `optimization`, `priority/p0`, `classification/scaling-risk`, `impact/high`, `effort/large`, `status/needs-design`
**Milestone:** Wave 4
**Depends on:** PERF-027 + PERF-001 for verification
**Audit reference:** OPT-003

**Problem.** With `{{nav}}` in the layout, every page embeds the whole site
forest: output bytes grow O(n²) (201 pages ≈ 5.7 MB; 1,001 ≈ 92 MB), and
every output-proportional phase inherits it. Build time is superlinear
(201→0.33 s, 401→1.98 s, 1,001→21.5 s). At 10k pages with this theme:
≈ 9 GB output, multi-hour builds; 100k: not buildable.

**Primary locus.** `themes/boris/layouts/main.html` (`{{nav}}`),
`src/html_nav.zig`, everything that reads output.

**Acceptance criteria**
- Design proposal first (theme option for bounded nav: depth, per-section
  children-of-ancestors, or CSS-only two-tier nav), reviewed against
  `docs/contracts/templating-and-themes.md`.
- If a nav-shape option lands: 5k corpus rebuild shows wall time and output
  MB vs current; `dist` remains byte-deterministic across `--jobs`
  (existing sequential/parallel byte-equality tests must pass).
- Compiler-side mitigation (PERF-001/004/031) lands regardless — the
  overlay/pipeline work helps for any nav shape, so this issue must not
  block Wave 4.

---

### PERF-027 — Add phase timing / counters instrumentation (`--timings`)

**Labels:** `perf`, `optimization`, `priority/p0`, `classification/observability`, `impact/high`, `effort/small-med`, `status/ready`
**Milestone:** Wave 0
**Depends on:** —
**Audit reference:** OPT-027

**Problem.** Boris has no built-in phase timing, counters, or `--timings`
surface. Every claim in the audit required external `sample` profiling and a
hand-built corpus; regressions (e.g., an accidental O(n²)) cannot be caught.

**Primary locus.** `src/compile.zig`, `src/pipeline.zig`, `src/cli.zig`.

**Acceptance criteria**
- `--timings` (or `--verbose-phases`) emits deterministic, machine-readable
  phase durations + counters: scan, parse, graph validate, dependency
  resolve, fingerprint, render, heading harvest, search, link audit,
  inventory, checks, claims, touches, proof pack; counters: page reads,
  include reads, hash bytes, link resolutions, fast-path hits.
- Default output path, diagnostics, exit codes, and `--quiet` unchanged;
  option is off unless requested.

---

## P1 issues (detailed)

### PERF-004 — Link-audit route resolution allocates per link

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/measured-bottleneck`, `impact/med-high`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1
**Depends on:** —
**Audit reference:** OPT-004

**Problem.** Every `href`/`src` in every published page goes through
`resolveWithinRoot` → `resolve` → `decode` (dupe + per-pass ArrayList +
`toOwnedSlice`) + segments + output: 4–6 allocations per reference. At 1,001
pages with a full nav that is ~1 M references per build; under Debug it is
the single hottest spot (`sample`: 1885/2330 samples in
`route_resolver.decode` → `toOwnedSlice` → DebugAllocator).

**Primary locus.** `src/route_resolver.zig` (`resolve`, `decode`),
`src/link_audit.zig` (`auditDocument`).

**Acceptance criteria**
- No-allocation fast path for the common case (no `%` escapes, no `..`/`.`,
  no leading/trailing `/`, no query/fragment): compute joined path into a
  caller stack buffer, copy once. Slow path unchanged.
- Existing `route_resolver` unit tests pass; resolution semantics
  byte-identical (escapes, `..` failure modes are contractual).
- Before/after timing on the 1,001-page corpus via PERF-027.

---

### PERF-005 — Warm incremental builds save almost nothing

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/incremental-build`, `impact/high`, `effort/medium`, `status/needs-measurement`
**Milestone:** Wave 3
**Depends on:** PERF-027, PERF-001
**Audit reference:** OPT-005

**Problem.** `--incremental` skips rendering clean pages, but every
subsequent phase (heading harvest, search, link audit, inventory, checks,
claims, touches, proof pack) still processes the full site. Measured:
401 pages — full 1.98 s vs warm incremental 1.81 s vs 1-page-change 1.71 s;
1,001 pages — full 21.5 s vs warm 21.7 s.

**Primary locus.** `src/compile.zig` post-render phases, `src/cache.zig`.

**Acceptance criteria**
- No-op incremental on 1k and 5k corpora measurably cheaper than full build
  (with PERF-027 timers); watch rebuilds per edit no longer pay full-build
  time.
- Evidence reports byte-identical to full-build reports.

**Notes for the implementer.** The evidence chain must always bind to the
exact committed bytes; reuse of touches/proof-pack derivation is only safe
when `artifacts.json`/`checks.json`/`claims.json` are byte-identical to
prior committed bytes. Same-size corruption safety must be proven (see
PERF-022).

---

### PERF-006 — Page sources are read 3–4× per build; reuse `SharedCompileState.source_bytes`

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/io`, `impact/medium`, `effort/small-med`, `status/ready`
**Milestone:** Wave 2
**Depends on:** —
**Audit reference:** OPT-006

**Problem.** In one HTML build each page source is read from disk at least
3×: `loadAndPromoteFormat` (frontmatter), `SharedCompileState.init`
(`populateDependencyIndexFormat` re-reads every source again), and
`renderPageSlots` (body render); `buildSiteHeadingIndex` re-reads
fragment-target pages. `shared.source_bytes` already holds all of it.

**Primary locus.** `src/compile.zig` (`renderPageSlots`,
`buildSiteHeadingIndex`, `loadAndPromoteFormat`), `src/html_body.zig`.

**Acceptance criteria**
- Thread pre-read source bytes (or slice views) from `SharedCompileState`
  into render/heading paths; keep the read path for no-shared-state callers.
- File-open counter (PERF-027) shows reads drop to ~1×; output byte-identical.

**Notes for the implementer.** `source_bytes` are GPA-owned and live for the
whole compile; arena views must not outlive them (they don't today).

---

### PERF-007 — `doclink.rewrite` runs twice per page; one result is discarded

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/probable`, `impact/medium`, `effort/medium`, `status/ready`
**Milestone:** Wave 2
**Depends on:** —
**Audit reference:** OPT-007

**Problem.** Dependency resolution runs `doclink.rewrite` over the full body
just to collect `reference_ids`, then frees the rewritten bytes
(`pipeline.zig` `scanPageWithHtmlLinks`); render runs `doclink.rewrite`
again on the same body (`html_body.renderSource`).

**Primary locus.** `src/pipeline.zig` (`scanPageWithHtmlLinks`),
`src/html_body.zig` (`renderSource`), `src/doclink.zig`.

**Acceptance criteria**
- Either a scan-only `reference_ids` API that doesn't build the rewritten
  buffer, or reuse of the dependency-phase rewrite when render has access to
  it (dependency resolution runs before render, so the rewritten body can be
  stored per page in shared state).
- Reference validation and diagnostics unchanged; outputs byte-identical;
  5k corpus before/after via PERF-027.

---

### PERF-008 — Include files are re-read per including page and re-parsed repeatedly

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/io`, `classification/memory`, `impact/medium`, `effort/medium`, `status/ready`
**Milestone:** Wave 2
**Depends on:** —
**Audit reference:** OPT-008

**Problem.** An include file used by P pages is read from disk P× by
`SharedCompileState.init` (fingerprints), P× again by the dependency scan,
P× again by `expandIncludes` (per-page cache only). `bodyOfSource`/
`lineBaseOfSource` re-run `parser.parse` per call.

**Primary locus.** `src/include.zig` (`expandIncludes`, `bodyOfSource`,
`readSourceAlloc`), `src/compile.zig` (`SharedCompileState.init`),
`src/pipeline.zig` (`scanIncludes`).

**Acceptance criteria**
- Build-session include cache keyed by content-root path: read once, shared
  refcounted buffer, reused parsed body view; per-page expansion cache kept.
- Include-open counter (PERF-027) drops to ~1 per path on a shared-fragment
  corpus; output byte-identical.
- No-follow/symlink-resolution policy and expansion budgets unchanged;
  diagnostics line mapping identical.

---

### PERF-009 — Site-nav fingerprint material is re-hashed per page

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/probable`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1
**Depends on:** cache-format bump (internal to the PR)
**Audit reference:** OPT-009

**Problem.** Each page fingerprint SHA-256-hashes the full
`site_nav_material` (all (id,title,parent,role) records — O(pages) bytes)
plus full layout bytes and theme material; the material is identical for
every page in a run. Total hashing is O(n²): at 5k pages, nav material
≈ 225 KB × 5k pages ≈ 1.1 GB SHA-256 per build (~1–3 s); at 100k with a
4 MB nav material that is 400 GB hashed — minutes.

**Primary locus.** `src/compile.zig` (`compilePagesInner` fingerprint loop),
`src/cache.zig` (`computePageFingerprintThemeInput`), `src/html_nav.zig`
(`siteNavMaterial`).

**Acceptance criteria**
- Hash each constant input (nav material, layout bytes, theme material) once
  per build; mix the 32-byte digest into per-page fingerprints (length-
  prefixed with an explicit marker).
- `CACHE_FORMAT_VERSION` bumped; exactly one cold invalidation on upgrade,
  then stable warm fingerprints. Fingerprints must change exactly once on
  upgrade (the marker guarantees this).
- 5k/20k corpus fingerprint-loop timing via PERF-027.

---

### PERF-010 — Incremental manifest lookup is O(pages × entries)

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1
**Depends on:** —
**Audit reference:** OPT-010

**Problem.** Per page, the incremental check linearly scans the entire prior
manifest (`compile.zig` `skip_render` block). 5,001-page warm incremental:
25 M string compares; 100k pages → 10¹⁰ (minutes).

**Primary locus.** `src/compile.zig` (incremental freshness loop, ~lines
2380–2410).

**Acceptance criteria**
- Build a `StringHashMap` (entity_id + output_path + target) → entry once
  per build; per-page O(1) lookup. Keep current first-match-wins semantics
  for duplicate/corrupt manifest entries.
- No-op incremental timing at 5k/20k improves (PERF-027).

---

### PERF-011 — `findNodeById` linear scan in freeze sync loop (O(n²))

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/probable`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1
**Depends on:** —
**Audit reference:** OPT-011

**Problem.** `freezeSiteFromPageDb` calls `findNodeById` (linear scan) once
per page to copy role/index/parent_index back from the frozen (id-sorted)
nodes. O(n²) eql on every HTML/IR-compiling run; 100k pages ≈ 10¹⁰ (minutes).

**Primary locus.** `src/compile.zig` (`findNodeById`,
`freezeSiteFromPageDb`).

**Acceptance criteria**
- Build id→index once (graph already has `buildIdIndex`) or binary-search
  the sorted slice; results identical. 20k/100k synthetic corpus timing
  before/after (PERF-027).

---

### PERF-013 — Wiki-link resolution scans all pages per link (`findPage`)

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1
**Depends on:** —
**Audit reference:** OPT-013

**Problem.** Every `[[entity]]` hit calls `findPage` — a linear scan of the
node list (`pipeline.zig` `scanWiki`). O(links × pages): a corpus where each
page links to 50 others at 100k pages is 5×10¹¹ eql — minutes.

**Primary locus.** `src/pipeline.zig` (`findPage`, `scanWiki`),
`src/wikilink.zig`.

**Acceptance criteria**
- Build the id set once per resolution pass; reuse. Diagnostic emission
  order and missing-link reporting identical (first-wins ordering).

---

### PERF-025 — Parallelize the post-render phases

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/parallelism`, `impact/high`, `effort/med-large`, `status/needs-design`
**Milestone:** Wave 4
**Depends on:** PERF-001, PERF-027
**Audit reference:** OPT-025

**Problem.** `--jobs` parallelizes only rendering (≈5 % of a 1k build —
jobs=4 ≈ jobs=1: 1.81 s vs 1.98 s at 401 pages). The dominating phases
(search, audit, checks) are serial per-page loops whose per-page work is
independent (page N's results don't depend on page M's), so deterministic
aggregation is achievable.

**Primary locus.** `src/compile.zig` post-render section,
`src/link_audit.zig`, `src/search_index.zig`, `src/publication_checks.zig`.

**Acceptance criteria**
- For each phase, split the page array across workers with per-page results
  merged in canonical (path-sorted) order; use the existing
  `ParallelContext` pattern (mutex + next_page_index + shared_error) as the
  in-repo template.
- `--jobs=1` vs `--jobs=8` full builds at 1k/5k show core-count scaling on
  the dominant phase; existing byte-equality tests across job counts pass.
- Evidence chain ordering preserved (checks runs after commit).

---

### PERF-028 — Benchmark corpus generator + CI performance regression gate

**Labels:** `perf`, `optimization`, `priority/p1`, `classification/observability`, `impact/high`, `effort/medium`, `status/ready`
**Milestone:** Wave 0
**Depends on:** PERF-027 (phase timings to assert)
**Audit reference:** OPT-028

**Problem.** No Boris-level benchmark exists (only vendored Apex
benchmarks). The opt-in scale smoke is 200 pages with a content-only layout
and no timing assertions. The measured cliffs (PERF-001/003/005) can
silently regress with no gate.

**Primary locus.** `test/`, `scripts/`, `.github/workflows/ci.yml`.

**Acceptance criteria**
- Checked-in deterministic corpus generator (reuse the fixture-generator
  pattern under `tools/testdata-generator`) producing 1k/5k page trees with
  a nav layout; `zig build benchmark` step (ReleaseFast-only) prints phase
  timings; CI job fails on >2× baseline regression with the corpus pinned.
- CI budget: ReleaseFast, start at 1k pages; grow after PERF-001 lands.

---

## P2 / P3 issues (condensed)

### PERF-012 — Reverse dependency index built with nested loop (O(E × T))
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/pipeline.zig` (`freezeDependencyIndex`).
**Fix:** single pass over edges appending into per-target lists (same shape
as `graph.buildNav` child lists), preserving sorted/deduped output semantics
asserted by tests. Prove: IR build at 20k/100k; `graph.json` reverseIndex
bytes unchanged. (Audit OPT-012.)

### PERF-014 — Scanner directory-cycle check is O(dirs²)
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/low-med`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/scanner.zig` (`identitySeen`, `scanDirFormat`).
**Fix:** hash set keyed by inode; cycle-detection semantics and error
precedence (SymlinkCycle vs SymlinkRejected) unchanged. Prove: 20k-dir tree
scan timing. (Audit OPT-014.)

### PERF-015 — Case-collision duplicate-id check is O(n²) worst case
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/low`, `effort/small-med`, `status/needs-design`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/graph.zig` (`diagnoseDuplicateIds`).
**Fix:** bucket ids by case-folded hash, compare within bucket. Correctness
surface: keep exact source-order first-wins reporting, byte-exact
`EDUPLICATEID` path, and `EINVALIDPATH` for case-only collisions. Needs
design review before implementation. (Audit OPT-015.)

### PERF-016 — Semantic-relation validation does a linear page lookup per relation
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/low-med`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/graph.zig` (`validateSemanticRelations`).
**Fix:** build the id map once (as `validateTopology` already does);
diagnostic order preserved. (Audit OPT-016.)

### PERF-017 — `rag_emit.renderRelations` is O(pages²)
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/rag_emit.zig` (`renderRelations`).
**Fix:** one child-list pass keyed by parent id (same shape as
`graph.buildNav`), render in id order. Prove: `--rag --complete` at
20k/100k; `graph/relations.md` byte-identical. (Audit OPT-017.)

### PERF-018 — `llms.zig` child lookup is O(pages²)
**Labels:** `perf`, `priority/p2`, `classification/scaling-risk`, `impact/medium`, `effort/small`, `status/ready`, `good-first-issue`
**Milestone:** Wave 1 · **Depends on:** —
**Locus:** `src/llms.zig` (`findChildren`, `renderPage`).
**Fix:** parent→children index built once; keep the unvisited fallback and
deterministic output order. Prove: llms export at 20k/100k. (Audit OPT-018.)

### PERF-019 — Theme bundle re-walked and re-read per target
**Labels:** `perf`, `priority/p2`, `classification/io`, `impact/medium`, `effort/small-med`, `status/ready`
**Milestone:** Wave 2 · **Depends on:** —
**Locus:** `src/theme.zig` (`loadThemeBundle`), `src/compile.zig`
(`compileHtmlSiteMulti`).
**Fix:** load the theme bundle once into shared state (bytes are
target-independent); per-target work reduces to copying shared bytes into
that target's stage. Per-target isolation, symlink/UTF-8 policy checks, and
collision checks still run per target. Prove: multi-target timing with a
real asset tree; both targets byte-identical to single-target builds.
(Audit OPT-019.)

### PERF-021 — Heading-harvest key re-hashes full source + include bytes per build
**Labels:** `perf`, `priority/p2`, `classification/probable`, `impact/low-med`, `effort/small`, `status/ready`
**Milestone:** Wave 1 · **Depends on:** heading-harvest format bump (internal)
**Locus:** `src/compile.zig` (`buildSiteHeadingIndex`, `headingHarvestKey`),
`src/cache.zig`.
**Fix:** reuse the per-page fingerprint (or its source+include portion) as
the harvest key, or compute from already-hashed inputs; bump
`HEADING_HARVEST_FORMAT`. Input-adapter identity must stay in the key; Apex
skip counts unchanged. (Audit OPT-021.)

### PERF-022 — Incremental digest verification reads and hashes every cached output
**Labels:** `perf`, `priority/p2`, `classification/io`, `impact/medium`, `effort/medium`, `status/needs-design`
**Milestone:** Wave 3 · **Depends on:** explicit tradeoff decision
**Locus:** `src/compile.zig` (incremental freshness block).
**Note:** this is an *intentional* integrity check (catches same-size
corruption of published HTML). Options in increasing aggressiveness: verify
digest only when size/mtime changed; rely on the post-commit checks pass and
document as defense-in-depth; sample-based verification. Each must document
the corruption cases it no longer catches; existing manifest-corruption
tests extended. Do not delete without the documented tradeoff. (Audit
OPT-022.)

### PERF-023 — `SharedCompileState` duplicates include bytes per including page
**Labels:** `perf`, `priority/p2`, `classification/memory`, `impact/medium`, `effort/medium`, `status/needs-design`
**Milestone:** Wave 2 · **Depends on:** PERF-008 (shared cache)
**Locus:** `src/compile.zig` (`SharedCompileState`).
**Fix:** refcount a per-path include cache (same object as PERF-008);
fingerprint consumers take the shared slice. Memory: 100k pages × 50 KB
shared header = 5 GB duplicated today. Prove: allocator high-water on a
shared-fragment 20k corpus. Ownership refactor — design first. (Audit
OPT-023.)

### PERF-024 — Checks/Doctor holds all page payloads in memory
**Labels:** `perf`, `priority/p3`, `classification/memory`, `impact/low`, `effort/medium`, `status/needs-measurement`
**Milestone:** Wave 4 · **Depends on:** PERF-001 (may be folded into it)
**Locus:** `src/publication_checks.zig` (`buildReport`), `src/doctor.zig`
(`TargetAnalysisBuilder`).
**Note:** observed footprint grew to 146 MB during the 5k checks phase.
Verify whether the builder needs all payloads simultaneously before
changing; `matchingRange` ownership attribution may require page lifetime.
Prove: RSS on 5k/20k before/after; `checks.json` byte-identical. (Audit
OPT-024.)

### PERF-029 — Scale smoke test should use a nav layout and assert phase behavior
**Labels:** `perf`, `priority/p2`, `classification/build-feedback`, `impact/medium`, `effort/small`, `status/ready`
**Milestone:** Wave 3 · **Depends on:** —
**Locus:** `src/incremental_scale_smoke_test.zig`.
**Fix:** add a smoke with the real `themes/boris/layouts/main.html` at ~1k
pages, asserting completion + deterministic output + a generous wall-time
budget that catches quadratic regressions without flaking. Keep opt-in;
ReleaseFast-only. The current smoke's `{{content}}`-only layout exercises
none of the measured cliffs. (Audit OPT-029.)

### PERF-030 — Document and standardize ReleaseFast builds for benchmarks/releases
**Labels:** `perf`, `priority/p3`, `classification/build-feedback`, `impact/low`, `effort/small`, `status/ready`
**Milestone:** Wave 0 · **Depends on:** —
**Locus:** `README.md`, `docs/STATUS.md`, `scripts/release-gate.sh`,
`build.zig`.
**Fix:** document `zig build -Doptimize=ReleaseFast`; add an optional
`-Drelease` step or a release-gate check. (Audit OPT-030.)

### PERF-031 — Single shared read pass over the overlay for search/audit/inventory
**Labels:** `perf`, `priority/p2`, `classification/io`, `impact/med-high`, `effort/med-large`, `status/needs-design`
**Milestone:** Wave 4 · **Depends on:** PERF-027
**Locus:** `src/compile.zig` post-render section, `src/search_index.zig`,
`src/link_audit.zig`, `src/artifact_inventory.zig`.
**Fix:** produce a per-page byte buffer array from the overlay once (bounded:
stream one page at a time through a worker chain, or hold the array with a
documented memory bound), feed search/audit/inventory consumers. Checks must
still read committed bytes post-commit (PERF-001). Overlay semantics (staged
wins, live fallback) and missing-page failures preserved exactly. (Audit
OPT-031.)

---

## Batches (recommended landing order)

| Wave | Name | Issues | Notes |
|---|---|---|---|
| 0 | Measurement infrastructure | PERF-027, PERF-028, PERF-030 | Prerequisite for honest before/after numbers; independent of all product work |
| 1 | Low-risk wins | PERF-009, PERF-010, PERF-011, PERF-012, PERF-013, PERF-014, PERF-016, PERF-017, PERF-018, PERF-021, PERF-004 | O(n²)→O(n) hash-map/index fixes + one allocation-free fast path; no behavior change, small diffs, `good-first-issue` candidates |
| 2 | I/O and memory | PERF-006, PERF-008, PERF-023, PERF-007, PERF-019, PERF-026 (fold into 019) | Shared read/byte reuse; PERF-023 depends on PERF-008 |
| 3 | Incremental compilation | PERF-022, PERF-005, PERF-029 | PERF-005 depends on PERF-001 + PERF-027; PERF-022 needs the documented tradeoff decision first |
| 4 | Large-corpus scaling / parallel rendering | PERF-001, PERF-031, PERF-025, PERF-003, PERF-024 (fold into 001) | PERF-025/031 depend on PERF-001; PERF-003 design work must not block the rest |
| 5 | Developer feedback speed | PERF-002 | Docs/CI guidance; the ~8.8× test-suite duplication is structural — documented in `docs/audits/test-throughput-audit.md`, only worth a card if maintainers accept test-file reorganization |

## Dependency graph

```
PERF-027 ──▶ PERF-001 ──▶ PERF-025
   │            │            │
   │            ├──▶ PERF-005
   │            └──▶ PERF-031
   ├──▶ PERF-028
   └──▶ PERF-003 (verification)

PERF-008 ──▶ PERF-023
PERF-022 ──▶ PERF-005 (tradeoff decision before)
PERF-009 / PERF-021: internal cache-format / harvest-format bumps
```

## Do not file (intentional costs, from the audit's "should remain" list)

These look inefficient but are required by Boris's correctness, security,
determinism, transaction, or evidence model. Do not convert into optimization
issues:

1. Checks re-hash/re-parse every committed artifact (`publication_checks.buildReport`).
2. Artifact inventory computes its own per-file digests.
3. Evidence chain re-reads artifacts/checks/claims per layer.
4. Incremental digest verification of cached outputs (PERF-022 is the
   documented-tradeoff exception: it may be *relaxed* only with an explicit
   decision, never deleted).
5. Per-page full nav rendering (the output *is* the product).
6. `validate` renders every page fully.
7. Default Debug build (PERF-002 is guidance, not a default change).
8. Full-tree stale-cleanup walk on non-incremental builds.

## Next step for the triage agent

File Wave 0 + Wave 1 issues first (13 issues: PERF-027, 028, 030, 009, 010,
011, 012, 013, 014, 016, 017, 018, 021, 004 — 14 including the four P0s where
ready). Wave 0 unblocks honest measurement for the remaining waves. Mark
PERF-003, 022, 023, 025, 015 as "needs design" and route to design review
rather than implementation.
