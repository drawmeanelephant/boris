# Code-health audit report — graph and pipeline

**Card:** [#811](https://github.com/drawmeanelephant/boris/issues/811) (milestone
[Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic
[#807](https://github.com/drawmeanelephant/boris/issues/807))
**Authority:** review only — no product-code changes on this card. Findings
filed individually: [#854], [#855], [#856].
**Commit audited:** `main` @ `c7b26186` (branch `audit/811-graph-pipeline`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin 27)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh branch `audit/811-graph-pipeline` from `main` tip `c7b26186` (== `origin/main`).
- `zig build test` → exit 0 before any probe work.
- Black-box probes: `zig build` binary `zig-out/bin/boris` (0.8.2) run against
  a scaffolded site (`boris init`) plus hand-built tmp content trees under
  `/var/folders/…/T/opencode/probe811/`; per-probe exit codes and output pasted
  below.
- Contracts read first: `docs/contracts/ir-schema.md` (normative), graph-shape
  rules in `publication-model.md` (Document facts / ownership matrix),
  cross-checks against `identity-and-paths.md` and `diagnostics.md`.
- Locus files read in full: `src/graph.zig` (1063), `src/dependency.zig` (92),
  `src/pipeline.zig` (2077). Supporting walks: `src/cache.zig` (NodeLookup /
  getAffectedPages), `src/artifact_sink.zig` (commit paths), `src/ir_emit.zig`
  (emit surface), `src/identity.zig` (`validateEntityId`).

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| B1 | Orphan satellite (parent → missing id) | `boris init`; add `content/orphan.md` with `parent: missing-parent`; `boris --out .boris --quiet` | `error: EPARENTMISSING: orphan.md:1:1: parent "missing-parent" does not exist [Create the parent document or fix the parent id]`, exit 1; `.boris/` contains **only** `build-report.json` (`ok: false`, `errorCount: 1`, compiler id present on the failure path) | Non-issue (contract-conformant) | graph.zig:321-337 (`EPARENTMISSING`), pipeline.zig:683-688 + artifact_sink.zig:135-145 (graph-dependent artifacts removed, report only); unit test `pipeline.test."invalid graph fixtures emit stable categories"` + `docs/contracts/fixtures/missing-parent/` |
| B2 | Cycle (A parent B, B parent A) | `content/a.md` (`parent: b`) + `content/b.md` (`parent: a`); `boris --out .boris` | exit 1; two `EPARENTCYCLE` diagnostics, one per participant, stable path message `parent cycle involving a -> b -> a`; only `build-report.json` published | Non-issue | graph.zig:344-429 (iterative gray-set DFS, per-cycle diagnostics), unit tests `validateTopology two-node cycle` / `longer cycle (3 nodes)` / `rejects a deep parent cycle`; fixture `docs/contracts/fixtures/cycles/` |
| B3 | Trunk/satellite acceptance + `schemaVersion` stability + determinism | trunk + two-level satellite tree (no facets); `boris --out out-a --quiet` and `--out out-b` | exit 0 both; `graph.json`/`manifest.json`/`build-report.json` all `"schemaVersion": "0.2.0"`, `compiler: boris/0.8.2`; `frozen: true`; `diff out-a/graph.json out-b/graph.json` → identical (and manifest identical); nav/breadcrumb root→self, direct-only children/siblings, `reverseIndex` ascending all conform | Non-issue (contract-conformant) | pipeline.zig:28-38 (base + conditional facet constants), ir_emit golden `pipeline.test."F8 graph-native fixture matches full graph golden"`, conditional-bump tests `"a corpus without recipes keeps its existing IR version"` / Cooklang 0.4.0 assertions |
| B4 | Mechanical IR-schema drift gate (both directions) | `zig build test-ir-schema` | exit 0 — freshly emitted IR validates against every published JSON Schema (required property dropped or undeclared property added would fail) | Non-issue | ir-schema.md:26-32 (gate definition), `schemas/ir-*.schema.json` |
| B5 | Entity `id:` override equal to another page's `sourcePath` (cache-key conflation precondition) | `content/guides/intro.md` (id `guides/intro`) + `content/aaa.md` with `id: guides/intro.md`; `boris --out out --quiet` | **exit 0, no diagnostic** — the colliding id is accepted; when the override page sorts first, `NodeLookup` maps key `"guides/intro.md"` to the wrong page (first-wins, `id` before `source_path`) | **Likely defect → [#854]** (cross-ref #815) | identity.zig:157-193 (no `.md`-suffix rejection), graph.zig:113-192 (dup check compares ids only), dependency.zig:29-91 + pipeline.zig:519-531 (untyped string keys), cache.zig:222-256, 271-320 |
| W1 | Ordering/invalidation assumption behind the frozen graph | white-box walk of `compile_cache.zig:147` → `cache.getAffectedPagesIndexed` → `dep_index.reverse` | Assumption: the internal `DependencyIndex` and `NodeLookup` treat **entity ids and source paths as one string key space**; safe only while no id equals another node's source path (B5 breaks it). Also: reverse lists preserve insertion order (hash-map), not canonical order — consumers sort downstream, but the fragility is the untyped key space, per #854 | **Likely defect → [#854]** | cache.zig:222-256 ("first node matching a key still wins"), pipeline.zig:408-410 (doc comment: "keyed by entity id … matching `getAffectedPages`") |
| W2 | Internal dependency-kind inventory vs contract | `grep -rn "\.asset\b\|html-link" src/*.zig`; read `ir-schema.md:485-487` | Contract names `layout`/`asset` as the internal kinds; code: `html-link` is active-but-unnamed (pipeline.zig:346, 526-529), `asset` is a dead variant (dependency.zig:19 only), `layout` is test-only (graph.zig:860; product call sites pass `null`, pipeline.zig:1074 TODO) | **Confirmed defect → [#856]** (low, contract text) | ir_emit.zig serializes only `result.edges` (parent/include/reference); `test-ir-schema` green confirms no IR leak |
| W3 | `completion.json` in the output-publication prose | read `ir-schema.md:38-67, 293-299` vs pipeline.zig:697-700, artifact_sink.zig:135-145 | Prose says "write all **three** JSON files" on success and deletes only `manifest.json` / `graph.json` on failure; contract's own Artifacts section and the code (four files; three deleted) say otherwise | **Confirmed defect → [#855]** (low, contract text) | artifact_sink.zig:135-145 deletes all three graph-dependent artifacts; unit tests `memory sink failure emits build-report only`, `duplicate id fails and does not publish graph-dependent IR` |

Non-issue observations recorded for the record (no action):

- Orphan/self-parented nodes keep `role = .satellite` with `parent_index = null`
  during validation (graph.zig:317-318, 335-336) — irrelevant post-failure since
  such builds never freeze or publish; conformant with "no role claim before
  freeze" (ir-schema.md rule 9).
- Case-colliding ids diagnose as `EINVALIDPATH`, not `EDUPLICATEID`
  (graph.zig:107-110, 174-189) — documented in `diagnostics.md:136` with the
  case-insensitive-FS rationale and a fixture. Non-issue.
- Cycle-path comment "sort participant ids then rebuild path in walk order"
  (graph.zig:382) describes only the second half — the path is rebuilt in walk
  order, never sorted; walk order is deterministic (discovery order). Stale
  comment only; Non-issue.
- `layout_path` is unwired on the IR compile path (pipeline.zig:1074 TODO);
  layouts remain HTML-internal per the contract. Documented limitation.
- Validation-order normative sequence (EDUPLICATEID → EPARENTSELF →
  EPARENTMISSING → EPARENTCYCLE) matches `graph.validate` (graph.zig:206-214,
  294-342) and is re-sorted deterministically at emit (sourcePath, line,
  column, code, message). Non-issue.
- `freeze` silently nulls `parent_index` for a parent id missing at freeze time
  (graph.zig:462-472) — defensive dead branch: `freeze` is reachable only after
  zero-error validation. Non-issue.

## Findings

1. **[#854] Likely defect (low):** an entity `id:` override may legally equal
   another page's `sourcePath`; the internal dependency index and `NodeLookup`
   key both in one untyped string namespace with first-wins resolution, so
   incremental invalidation can seed from the wrong page → stale HTML.
   Cross-ref #815. Locus `identity.zig:157-193`, `graph.zig:113-192`,
   `dependency.zig:29-91`, `pipeline.zig:519-531`, `cache.zig:222-256`.
2. **[#855] Confirmed defect (low, contract text):** `ir-schema.md`
   § Output publication behavior is stale — "three JSON files" and the
   failure-delete list omit `completion.json`, contradicting the same
   contract's Artifacts section and the conformant code. Locus
   `docs/contracts/ir-schema.md:293-299`.
3. **[#856] Confirmed defect (low, contract text):** internal dependency-kind
   inventory drifted — contract names `layout`/`asset`; the active extra kind
   is `html-link` (unnamed), `asset` is a dead variant, `layout` is test-only.
   Locus `docs/contracts/ir-schema.md:485-487`, `dependency.zig:3-22`,
   `pipeline.zig:346,526-529`, `graph.zig:484-493`.

## Exit checklist

- [x] 2 card-listed contracts read first (ir-schema.md normative;
      publication-model.md graph-shape rules), plus identity-and-paths.md and
      diagnostics.md cross-checks
- [x] 3 locus files read in full; drift checked both directions
- [x] 8 falsification probes (4 black-box runs B1–B5 incl. two-run
      determinism diff, plus 4 white-box walks/gates), ≥2 black-box: satisfied
- [x] Every material observation classified exactly once
- [x] Findings filed individually: #854 (Likely), #855 (Confirmed), #856
      (Confirmed)
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #811 with the mandated template
