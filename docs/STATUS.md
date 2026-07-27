# Project status — Boris

**As of:** 2026-07-26

**Integration line:** `afterparty` during the Build Week judging window; `main` is frozen.

**Product metadata:** `v0.8.1 candidate` / `boris/0.8.1`; base IR `schemaVersion` **`0.2.0`**.
**Phase:** post-v0.8 integration and release reconciliation.

**Build baseline:** Zig **0.16** and CMake for the vendored ApexMarkdown static libraries.

Boris is a Zig documentation compiler: Markdown in, validated documentation
graph out as HTML by default, with optional IR, RAG, Context Bundle, and
`llms.txt` exports. It is not a Node SSG, an MDX runtime, or a migration
framework. Normative behavior lives in [`docs/contracts/`](contracts/);
release history lives in [`CHANGELOG.md`](../CHANGELOG.md).

## Read this first

- The next release is **v0.8.1 candidate**. It must not be tagged until release
  context is complete. The historical `v0.8.0` tag remains preserved as
  erroneous evidence: it resolves to a commit carrying 0.7.0 metadata and is
  not an ancestor of `afterparty`.
- The current afterparty merge set is PRs **#228–#246**: generated-output
  hygiene, docs-maintenance hardening, default-site layout polish, rendered
  search foundation, CLI hardening, browser UI, and staged publication,
  standalone-tool CI, nested hierarchy, human-first documentation IA, and the
  status, release-packet, fragment-normalization, relationship-inventory,
  theme-dogfood, and archive-review work in PRs #238–#244.
- Rendered-site search is **shipped on `afterparty`**: the compiler produces the
  search artifact from its staged live-page overlay and the default layout has
  a small browser UI with a no-JavaScript navigation fallback. Its normative
  artifact surface is [`rendered-search.md`](contracts/rendered-search.md).

## What works

| Capability | Current state |
|---|---|
| Default site build | **Done** — `boris` writes HTML to `dist/`. |
| Markdown rendering | **Done** — in-process ApexMarkdown Unified, including tables and footnotes. |
| Content graph | **Done** — closed frontmatter, validated Trunk/Satellite hierarchy, includes, wiki links, heading targets, and recursive validated parent chains. |
| HTML navigation and layouts | **Done** — graph-backed nav, breadcrumbs, TOC, closed layout slots, assets, layout rules, incremental/watch/jobs, and isolated targets. |
| Machine outputs | **Done** — IR 0.2, RAG, Context Bundles, and `llms.txt`; semantic relations retain their documented conditional IR 0.3 artifacts. |
| Migration laboratories | **Done as bounded developer tools** — read-only review, conversion aids, relationship candidates, and theme materialization; they do not widen Boris author grammar. |
| Rendered-site search | **Done on `afterparty`** — deterministic staged compiler publication, standalone CLI, browser UI, zero-results state, and no-JavaScript navigation fallback. |
| Relationship review inventory | **Done on `afterparty`** — schema-v2 exact target inventory preserves provenance, duplicate keys, slug states, draft exclusion, unsupported-file rows, and deterministic JSON/Markdown reports. |
| Relationship candidate classification | **Done on `afterparty`** — exact eligible-key review output reports `inventoried`, `ambiguous`, `absent`, and `invalid`; no automatic selection or relation emission. |
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
./zig-out/bin/boris --out .boris --quiet            # IR only
./zig-out/bin/boris --rag --quiet                   # RAG → rag/
./zig-out/bin/boris --context --quiet               # Context Bundle
./zig-out/bin/boris --llms --quiet                  # llms.txt
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
| 3 | Archive browser review | **Next evidence pass** | Inspect the retained fixture at 375px, 768px, and 1440px plus keyboard traversal; record actual evidence before changing layout behavior. |
| 4 | Archive presentation fixes | **Evidence-gated** | Small, framework-free HTML/CSS or layout fixes only after the browser review finds a reproducible issue. |
| 5 | Migration-guide executable pass | **Evidence complete — review findings remain** | 69-page Starlight dogfood converted and compiled successfully; review the retained MDX/frontmatter/link/asset findings and four generated-site missing routes before claiming a clean migration. |
| 6 | Source-RAG ergonomics measurement | **Measured — no behavior change** | Default flat export: 988 source files, 16,012 KiB on disk, 1.48s. `--no-bundles`: 9,468 KiB, 1.13s. Bundles-only at 256 KiB: 7,084 KiB, 28 parts, 1.14s. Core/docs bundles-only: 1,668/3,448 KiB. Tools per-pack: 6 packs, 2,224 KiB, 0.61s. Keep product RAG distinct. |
| 7 | Source-RAG publication safety | **Dependent on evidence** | Make only a tested, narrowly justified staging/cleanup improvement. |
| 8 | Build optimization | **Deferred** | Measure cold/repeated/parallel/incremental runs first; preserve current deterministic coordinator model unless data justifies change. |

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
- All retained fragments have numeric names, a permitted category heading, and
  a deterministic 33-row [`fragment inventory`](changelog.d/INVENTORY.md).
  The release owner still decides whether and when to consume them.
- The release gate now correctly accepts the validated nested hierarchy fixture.

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
| [`CHANGELOG.md`](../CHANGELOG.md) | Released-history record |
| [`docs/changelog.d/`](changelog.d/) | Pending release fragments |
| [`docs/MIGRATION.md`](MIGRATION.md) | Bounded author migration workflow |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone migration-lab commands |
| [`tools/search-index/README.md`](../tools/search-index/README.md) | Rendered search tool |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Mechanical ship checks |
| [`AGENTS.md`](../AGENTS.md) | Repository policy and agent constraints |
