# Project status — Boris

**As of:** 2026-08-08

**Integration line:** `afterparty` during the Build Week judging window; `main` is frozen.

**Product metadata:** `v0.8.1 candidate` / `boris/0.8.1`; base IR `schemaVersion` **`0.2.0`**.
**Phase:** post-v0.8 integration and release reconciliation.

**Build baseline:** Zig **0.16** and CMake for the vendored ApexMarkdown static libraries.

Boris is a Zig documentation compiler: Markdown in, validated documentation
graph out as HTML by default, with optional IR, RAG, Context Bundle, and
`llms.txt`, and RSS 2.0 exports. It is not a Node SSG, an MDX runtime, or a migration
framework. Normative behavior lives in [`docs/contracts/`](contracts/);
release history lives in [`CHANGELOG.md`](../CHANGELOG.md).
The publication-model boundary is canonically defined by
[`publication-model.md`](contracts/publication-model.md); it does not add
frontmatter or claim a unified publication executor.

## Read this first

- The next release is **v0.8.1 candidate**. It must not be tagged until release
  context is complete. The historical `v0.8.0` tag remains preserved as
  erroneous evidence: it resolves to a commit carrying 0.7.0 metadata and is
  not an ancestor of `afterparty`.
- The current afterparty merge set runs through PR **#311**: generated-output
  hygiene, docs-maintenance hardening, default-site layout polish, rendered
  search foundation, CLI hardening, browser UI, staged publication,
  standalone-tool CI, nested hierarchy, human-first documentation IA, the
  release-state packet and fragment normalization, relationship inventory and
  candidate classification, theme-dogfood and archive review, migration-lab
  publication safety, RSS 2.0 and sitemap exports, the publication profile /
  plan / artifact-inventory / checks / claims evidence chain, the Touch Atlas
  (contract and first slice), testdata-generator and jobs passthrough, the
  test-throughput audit, and the Proof Pack (contract, first slice, semantic
  rejection probes, HTML presentation, and print-disclosure robustness),
  release bookkeeping, the standalone content audit, and parser-authority
  cleanup in PRs #275–#311.
- Rendered-site search is **shipped on `afterparty`**: the compiler produces the
  search artifact from its staged live-page overlay and the default layout has
  a small browser UI with a no-JavaScript navigation fallback. Its normative
  artifact surface is [`rendered-search.md`](contracts/rendered-search.md).
- Product RAG is now a **working-context projection**: default `--rag` emits
  bounded `working-N.md` upload packs of verbatim site documents (never the
  `docs/rag/system` corpus) plus a `manifest.json` sidecar (schema v2), and
  `--rag --complete` is the explicit full-corpus export that rejects `--scope`.
  Normative surface:
  [`rag-export.md`](contracts/rag-export.md).

## What works

| Capability | Current state |
|---|---|
| Default site build | **Done** — `boris` writes HTML to `dist/`. |
| Markdown rendering | **Done** — in-process ApexMarkdown Unified, including tables and footnotes. |
| Content graph | **Done** — closed frontmatter, validated Trunk/Satellite hierarchy with arbitrary finite acyclic parent chains, includes, wiki links, and heading targets. |
| No-publication validation | **Done on `afterparty`** — `boris validate` reuses the canonical HTML prepublication compiler path for source, graph, dependency, component, layout, theme, asset, and sitemap validity without creating target, cache, search, or evidence artifacts. |
| HTML navigation and layouts | **Done** — graph-backed nav, breadcrumbs, TOC, closed layout slots, assets, layout rules, incremental/watch/jobs, isolated targets, and opt-in deterministic XML sitemap publication. |
| Machine outputs | **Done** — IR 0.2, RAG (working-context packs + `--complete` corpus, schema 2), Context Bundles, `llms.txt`, and deterministic RSS 2.0; semantic relations retain their documented conditional IR 0.3 artifacts. |
| Migration laboratories | **Done as bounded developer tools** — read-only review, conversion aids, relationship candidates, and theme materialization; they do not widen Boris author grammar. |
| Rendered-site search | **Done on `afterparty`** — deterministic staged compiler publication, standalone CLI, browser UI, zero-results state, and no-JavaScript navigation fallback. |
| Relationship review inventory | **Done on `afterparty`** — schema-v2 exact target inventory preserves provenance, duplicate keys, slug states, draft exclusion, unsupported-file rows, and deterministic JSON/Markdown reports. |
| Relationship candidate classification | **Done on `afterparty`** — exact eligible-key review output reports `inventoried`, `ambiguous`, `absent`, and `invalid`; no automatic selection or relation emission. |
| Publication Touch Atlas | **Implemented first slice** — deterministic target-local `touches.json` relationship index derived exclusively from the committed bytes of `artifacts.json`, `checks.json`, and `claims.json`; runs after claims replacement with no payload rereads; OOM-safe construction. |
| Publication Proof Pack | **Done (Step 2C closed)** — deterministic two-file presentation model (`proof-pack.json` + `index.html`) over committed artifact, checks, claims, and Touch Atlas evidence; emitted after the Touch Atlas commits with a staged transaction, embedded model digest, semantic-rejection probes, improved HTML presentation, and print-disclosure robustness. |
| GitHub Pages publication target | **Implemented first slice** — normalized project/root/custom-domain location identity, strict public-target/site-URL validation, official Pages Actions workflow, exact public-inventory packaging, and retained evidence binding; post-deploy HTTP audit remains explicitly unverified. |
| Migration-guide executable pass | **Evidence complete** — the 69-page Starlight dogfood converted, compiled to HTML/IR/RAG, and produced a deployable static tree; human review remains required for 109 preserved, 1 stripped, and 79 manual-review findings plus four link-audit misses. |
| Source-RAG ergonomics measurement | **Measured** — flat, no-bundle, bundles-only, core/docs profiles, and per-tool packs were timed and sized; no behavior change is justified by this snapshot. |
| Archive-layout evidence | **Done mechanically** — deterministic fixture, black-box audit, and link audit pass; browser viewport and keyboard review remain explicitly unverified. |
| Twenty Twenty materialization dogfood | **Done** — bounded GPL-evidenced archaeology → reviewed ledger → static materialization → Boris build → link audit; no PHP/JS runtime behavior was adopted. |

### Common commands

```bash
zig build
zig build test
./scripts/release-gate.sh

./zig-out/bin/boris --quiet                         # HTML → dist/
./zig-out/bin/boris validate --quiet                # prepublication validation; no output
./zig-out/bin/boris --out .boris --quiet            # IR only
./zig-out/bin/boris --rag --quiet                   # RAG working packs → rag/
./zig-out/bin/boris --rag --complete --quiet        # complete-corpus RAG → rag/
./zig-out/bin/boris --context --quiet               # Context Bundle
./zig-out/bin/boris --llms --quiet                  # llms.txt
./zig-out/bin/boris --rss --site-url https://docs.example/ --rss-title "Example Docs" --rss-description "Recent updates" --quiet
./zig-out/bin/boris --sitemap --site-url https://docs.example/ --quiet
./zig-out/bin/boris --incremental --jobs 4 --quiet

zig build --build-file tools/search-index/build.zig test
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search

zig build --build-file tools/migration-lab/build.zig test
zig build test-layout-hostile
```

## Active roadmap

| Order | Card | State | Boundary / verification |
|---:|---|---|---|
| 1 | Release-state decision | **Decided — pending release context** | Preserve the erroneous v0.8.0 tag and use the new v0.8.1 identifier; do not tag or publish until release context is complete. Then run [`release-gate.sh`](../scripts/release-gate.sh). |
| 2 | Relationship candidate classification | **Done on `afterparty`** | Exact eligible-key review evidence is complete; `selected` remains reserved for a future explicit rule. |
| 3 | Publication Touch Atlas | **Implemented first slice** | Derives and atomically replaces `touches.json` after claims commit; the contract's non-claims (source provenance, runtime traces, deployment graph, accessibility/prose inference, proof-pack, repairs) remain out of scope. |
| 4 | Archive browser review | **Next evidence pass** | Inspect the retained fixture at 375px, 768px, and 1440px plus keyboard traversal; record actual evidence before changing layout behavior. |
| 5 | Archive presentation fixes | **Evidence-gated** | Small, framework-free HTML/CSS or layout fixes only after the browser review finds a reproducible issue. |
| 6 | Migration-guide executable pass | **Evidence complete — review findings remain** | 69-page Starlight dogfood converted and compiled successfully; review the retained MDX/frontmatter/link/asset findings and four generated-site missing routes before claiming a clean migration. |
| 7 | Source-RAG ergonomics measurement | **Measured — no behavior change** | Default flat export: 988 source files, 16,012 KiB on disk, 1.48s. `--no-bundles`: 9,468 KiB, 1.13s. Bundles-only at 256 KiB: 7,084 KiB, 28 parts, 1.14s. Core/docs bundles-only: 1,668/3,448 KiB. Tools per-pack: 6 packs, 2,224 KiB, 0.61s. Keep product RAG distinct. |
| 8 | Source-RAG publication safety | **Dependent on evidence** | Make only a tested, narrowly justified staging/cleanup improvement. |
| 9 | Build optimization | **Measured — no change** | Throughput audit: `zig build test` graph is fully sibling-parallel (42 flat test-run deps); scaling `-j1`→`-j8` ≈3x; warm default ≈16–20s. Residual floor is structural ≈8.8× shared-suite duplication across four co-dominant roots (`main`, `compile`, `hardening_test`, `layout_select_hostile_test`); no single root dominates. See [test-throughput-audit.md](audits/test-throughput-audit.md). |
| 10 | Publication Proof Pack (Phase 7A) | **Done — Step 2C closed** | Deterministic `proof-pack.json` presentation model and static `index.html` emitted after the Touch Atlas commits; strict four-report binding, canonical JSON/HTML rendering, first-slice staged transaction with embedded model digest, exit-3 mapping, quiet diagnostic capture, semantic-rejection probes, HTML presentation cleanup, and print-disclosure robustness. |
| 11 | GitHub Pages publication target (Issue #302) | **Implemented first slice** | Validate the Pages location offline, build with the official Actions sequence, package only exact inventory records, and retain proof/evidence separately. A future card may add a post-deploy URL audit and broader projection URL invariants. |

## Release bookkeeping

`CHANGELOG.md` is the historical release record; fragments under
[`docs/changelog.d/`](changelog.d/) are the queued release input. During normal
work, add one fragment for user- or contract-visible changes rather than editing
`CHANGELOG.md`’s shared **Unreleased** section. At release cut, the release
owner alone assembles and removes/archives fragments in deterministic order.

The release audit found these follow-ups:

- Preserve the historical `v0.8.0` tag as erroneous evidence; the next
  candidate is `v0.8.1`, which remains untagged until release context is
  complete.
- Retained fragments have a permitted category heading and are tracked in a
  deterministic 91-row [`fragment inventory`](changelog.d/INVENTORY.md); one
  unnumbered fragment (`twentytwenty-theme-materialization-dogfood.md`) is
  retained as found and awaits release-owner placement. The release owner
  still decides whether and when to consume them.
- The release gate now correctly accepts the validated four-level nested hierarchy fixture.

## Product boundaries that remain deliberate

| Not now | Reason |
|---|---|
| Subprocess Markdown rendering | Apex remains in-process through the C ABI. |
| Node/React/Astro/Next as the compiler | Boris itself is the Zig compiler. |
| Full YAML frontmatter or arbitrary MDX | The author grammar and registered components are intentionally closed. |
| Embedded HTTP server | Serve generated `dist/` with any ordinary static host. |
| Universal migration conversion | Migration labs are review-first, bounded developer tools. |
| Speed or cross-OS-byte-identity claims | Measure the specific workload and platform first. |

## Risk and environment notes

- HTML/IR/RAG publication uses staging and rename where supported; cross-volume
  whole-tree atomicity is not claimed.
- Symlink tests may skip when the host denies symlink creation.
- Default HTML assumes trusted author input because Apex raw HTML passes through.
- `--jobs` is bounded HTML rendering; graph discovery, resolution, and commit
  phases remain coordinated for deterministic output.
- Generated directories (`dist/`, `rag/`, `source-rag/`, caches, and temporary
  release-gate output) are not source-of-truth or review currency.

## Documentation map

| Document | Use it for |
|---|---|
| [`README.md`](../README.md) | Product outcomes and quick start |
| [`docs/contracts/`](contracts/) | Normative compiler and artifact behavior |
| [`docs/contracts/publication-model.md`](contracts/publication-model.md) | Canonical ownership of document facts, publication facts, migration provenance, projections, and verification claims |
| [`CHANGELOG.md`](../CHANGELOG.md) | Released-history record |
| [`docs/changelog.d/`](changelog.d/) | Pending release fragments |
| [`docs/MIGRATION.md`](MIGRATION.md) | Bounded author migration workflow |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone migration-lab commands |
| [`tools/search-index/README.md`](../tools/search-index/README.md) | Rendered search tool |
| [`docs/github-pages.md`](github-pages.md) | GitHub Pages setup, location model, workflow, and evidence boundary |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Mechanical ship checks |
| [`AGENTS.md`](../AGENTS.md) | Repository policy and agent constraints |
