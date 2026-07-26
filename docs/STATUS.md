# Project status — Boris

**As of:** 2026-07-26

**Integration line:** `afterparty` during the Build Week judging window; `main` is frozen.

**Product metadata:** `v0.8.0` / `boris/0.8.0`; base IR `schemaVersion` **`0.2.0`**.
**Phase:** post-v0.8 integration and release reconciliation.

**Build baseline:** Zig **0.16** and CMake for the vendored ApexMarkdown static libraries.

Boris is a Zig documentation compiler: Markdown in, validated documentation
graph out as HTML by default, with optional IR, RAG, Context Bundle, and
`llms.txt` exports. It is not a Node SSG, an MDX runtime, or a migration
framework. Normative behavior lives in [`docs/contracts/`](contracts/);
release history lives in [`CHANGELOG.md`](../CHANGELOG.md).

## Read this first

- The next release is **not ready to tag** until a release owner resolves the
  `v0.8.0` tag/metadata discrepancy. The tag currently resolves to a commit
  carrying 0.7.0 metadata and is not an ancestor of `afterparty`; no agent has
  moved it.
- The current afterparty merge set is PRs **#228–#238**: generated-output
  hygiene, docs-maintenance hardening, default-site layout polish, rendered
  search foundation, CLI hardening, browser UI, and staged publication,
  standalone-tool CI, nested hierarchy, human-first documentation IA, and the
  status/relationship/archive audit work in PR #238.
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
| Archive-layout audit fixture | **Ready to land** — deterministic fixture and black-box audit are on the current topic branch; manual visual/keyboard review remains required. |
| Relationship slug-object hardening | **Ready to land** — fail-closed `{ slug: "…" }` extraction coverage is on the current topic branch; inventory and resolution remain separate work. |

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
| 1 | Release-state decision | **Release owner needed** | Decide how to recover the v0.8.0 tag/metadata mismatch; do not retag, publish, or consume fragments by accident. Then run [`release-gate.sh`](../scripts/release-gate.sh). |
| 2 | Relationship target inventory | **Next** | Deterministic migration-lab inventory only: exact keys, provenance, duplicates, eligibility. No core frontmatter change or automatic semantic-relation emission. |
| 3 | Relationship candidate classification | **After inventory** | Report `selected`, `inventoried`, `ambiguous`, `absent`, or `invalid`; no fuzzy matching or first-match behavior. |
| 4 | Archive-layout manual review | **Next after fixture lands** | Review the archive fixture at mobile, tablet, and desktop widths; record evidence before changing layout behavior. |
| 5 | Archive presentation fixes | **Evidence-gated** | Small, framework-free HTML/CSS or layout fixes only after the audit identifies a reproducible issue. |
| 6 | Real-theme materialization dogfood | **Later** | One licensed static sample through archaeology → reviewed ledger → materialization → Boris build → link audit. Not a universal converter. |
| 7 | Migration-guide executable pass | **Later** | Verify the existing inspect → review → representative conversion → build → deploy path without implying CMS/MDX/framework parity. |
| 8 | Source-RAG ergonomics measurement | **Later** | Measure profiles, bundle sizes, and publish modes before changing behavior. Keep product RAG distinct. |
| 9 | Source-RAG publication safety | **Dependent on evidence** | Make only a tested, narrowly justified staging/cleanup improvement. |
| 10 | Build optimization | **Deferred** | Measure cold/repeated/parallel/incremental runs first; preserve current deterministic coordinator model unless data justifies change. |

## Release bookkeeping

`CHANGELOG.md` is the historical release record; fragments under
[`docs/changelog.d/`](changelog.d/) are the queued release input. During normal
work, add one fragment for user- or contract-visible changes rather than editing
`CHANGELOG.md`’s shared **Unreleased** section. At release cut, the release
owner alone assembles and removes/archives fragments in deterministic order.

The release audit found these follow-ups:

- Resolve the `v0.8.0` tag/metadata contradiction before describing v0.8.0 as a
  completed tagged release.
- Classify the remaining unnumbered fragments and add missing category headings
  before assembly. Existing numeric fragments remain retained; none were
  consumed by the audit.
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
