# Project status — Boris

**As of:** 2026-08-16

**Integration line:** `afterparty` during the Build Week judging window; `main` is frozen.

**Product metadata:** `v0.8.1 candidate` / `boris/0.8.1`; base IR `schemaVersion` **`0.2.0`**.
**Phase:** post-v0.8 integration and identity reconciliation.
**Afterparty tip:** PR **#532** (Standard.site first-tester path). The line is past **#524**; it is not “the merge set through #318.”

**Build baseline:** Zig **0.16** and the Oliver library pinned in `build.zig.zon` (pure Zig; no CMake or other host tools).

## Identity

**Choice (issue [#538](https://github.com/drawmeanelephant/boris/issues/538)): publisher platform.**

Boris is a **graph-native publication compiler** with multiple targets.
Markdown in, a validated Trunk/Satellite graph, then one or more contracted
projections. HTML `dist/` is the **default target**, not the whole product.

| Layer | What it is |
|---|---|
| Compiler core | One Zig binary. Closed frontmatter. Oliver in-process. Fail-loud graph. Default CLI writes `dist/`. |
| Publication targets | A registry. GitHub Pages and Standard.site are verified. Nostr plan/sign/publish is shipped and is not a verified target. |
| Evidence chain | `artifacts.json` → `checks.json` → `claims.json` → `touches.json` → Proof Pack. |
| Editor | In-tree authoring surface. Compiler-backed. Not a second stack. |
| Labs | Standalone migration and source-RAG tools. In the repo story. Not runtime dependencies. |
| Parked | Cloudflare Containers (#300) and freestanding Wasm (#301). Open cards, not shipped targets. |

This is not “a bookseller with a few extras in the basement.” It is also not
two products sharing a git remote. One compiler, several targets, one graph.

Normative behavior lives in [`docs/contracts/`](contracts/).
The publication-model boundary is
[`publication-model.md`](contracts/publication-model.md).
The target registry is
[`publication-platforms.md`](contracts/publication-platforms.md).
Release history lives in [`CHANGELOG.md`](../CHANGELOG.md).

## Read this first

- The next release is **v0.8.1 candidate**. It must not be tagged until release
  context is complete. The historical `v0.8.0` tag remains preserved as
  erroneous evidence: it resolves to a commit carrying 0.7.0 metadata and is
  not an ancestor of `afterparty`. More than **200** fragments sit under
  [`docs/changelog.d/`](changelog.d/). That queue is release-owner work. This
  status page does not cut the release.
- A stranger’s first command is still `zig build && ./zig-out/bin/boris --quiet`.
  That publishes HTML to `dist/`. Everything else is an explicit target,
  projection, or annex — named below, not hidden.
- Rendered-site search is **shipped**: the compiler produces the search
  artifact from its staged live-page overlay and the default layout has a
  small browser UI with a no-JavaScript navigation fallback.
  [`rendered-search.md`](contracts/rendered-search.md).
- Product RAG is a **working-context projection**: default `--rag` emits
  bounded `working-N.md` upload packs of verbatim site documents (never the
  `docs/rag/system` corpus) plus a `manifest.json` sidecar (schema v2).
  `--rag --complete` is the explicit full-corpus export and rejects `--scope`.
  [`rag-export.md`](contracts/rag-export.md).

## What works

### Compiler core

| Capability | Current state |
|---|---|
| Default site build | **Done** — `boris` writes HTML to `dist/`. |
| Markdown rendering | **Done** — Oliver (pinned in `build.zig.zon`) through `src/render.zig`: CommonMark + GFM tables + heading ids/IAL, footnotes, definition lists, strikethrough. |
| Content graph | **Done** — closed frontmatter, validated Trunk/Satellite hierarchy with arbitrary finite acyclic parent chains, includes, wiki links, and heading targets. |
| No-publication validation | **Done** — `boris validate` reuses the canonical HTML prepublication compiler path and writes no target, cache, search, or evidence artifacts. |
| HTML navigation and layouts | **Done** — graph-backed nav, breadcrumbs, TOC, closed layout slots, assets, layout rules, incremental/watch/jobs, isolated targets, opt-in XML sitemap. |
| Machine outputs | **Done** — IR 0.2, RAG (working-context packs + `--complete` corpus, schema 2), Context Bundles, `llms.txt`, deterministic RSS 2.0; semantic relations retain their documented conditional IR 0.3 artifacts. |

### Publication targets

| Target | Current state |
|---|---|
| GitHub Pages | **Shipped and verified** — normalized project/root/custom-domain identity, exact public artifact boundary, retained target-local evidence, optional bounded post-deploy observer. Operator path: [`github-pages.md`](github-pages.md). |
| Standard.site / AT Protocol | **Shipped for first testers** — offline plan/records/verify, opt-in app-password login, one-shot publish, recorded passing bsky.social live smoke. Browser OAuth is implemented; bsky.social does not grant `site.standard.authFull` (exit 6). Operator path: [`standard-site.md`](standard-site.md). |
| Publication evidence | **Done** — artifacts → checks → claims → Touch Atlas → Proof Pack, staged, deterministic. |
| Nostr NIP-23 | **CLI shipped, not a verified target** — `boris nostr plan` / `sign` / `publish` (BIP-340, bounded RFC-6455, per-relay verdict). Plan emits NIP-19 `naddr` / `npub`. `boris --profile` emits `nostr:naddr` alternate links on eligible pages. No location adapter, no Proof Pack, no live-smoke gate. Guide: [`content/guides/nostr-publication.md`](../content/guides/nostr-publication.md). |

### Editor

| Capability | Current state |
|---|---|
| Boris Editor | **First-class authoring surface** — local host, schema- and graph-aware completion, compiler-backed problems, live preview of committed `dist/`. Conformance campaign: [#418](https://github.com/drawmeanelephant/boris/issues/418) / [#462](https://github.com/drawmeanelephant/boris/issues/462). Guide: [`content/guides/editor.md`](../content/guides/editor.md). |

### Labs

| Capability | Current state |
|---|---|
| Migration laboratories | **Done as bounded developer tools** — read-only review, conversion aids, relationship candidates, theme materialization. They do not widen Boris author grammar. |
| Relationship inventory + classification | **Done** — schema-v2 inventory and exact eligible-key classification (`inventoried`, `ambiguous`, `absent`, `invalid`). No automatic relation emission. |
| Migration-guide executable pass | **Evidence complete** — 69-page Starlight dogfood converted and compiled; human review remains for preserved/stripped/manual-review findings. |
| Source-RAG ergonomics | **Measured** — no behavior change justified by the snapshot. |
| Archive-layout evidence | **Done mechanically** — fixture, black-box audit, and link audit pass; browser viewport and keyboard review remain unverified. |
| Twenty Twenty materialization | **Done** — bounded GPL-evidenced archaeology → reviewed ledger → static materialization → Boris build → link audit. |
| Filed.fyi / theme dogfood reports | **Retired** — long-form `docs/dogfood/` writeups deleted. Facts stay in this table. Human review findings for the Starlight migration-guide pass remain on the roadmap. |

### Parked / open

| Card | State |
|---|---|
| Cloudflare Containers (#300) | Open. Native Boris behind a Worker. Not a static rehost. |
| Freestanding Wasm (#301) | Open. Compiler-shaped embedding bet. |
| Standard.site HTML verify emit ([#533](https://github.com/drawmeanelephant/boris/issues/533)) | Production HTML never emits verification surfaces. Plan/publish do not wait on it. |
| Standard.site `boris init` profile ([#528](https://github.com/drawmeanelephant/boris/issues/528)) | Open. |
| ATProto DPoP wire ([#536](https://github.com/drawmeanelephant/boris/issues/536)) | Open. |
| Standard.site profile `pds` ([#537](https://github.com/drawmeanelephant/boris/issues/537)) | Contract treats it as optional; publish currently requires it. |
| publication-profile “Pages only” prose ([#534](https://github.com/drawmeanelephant/boris/issues/534)) | Filed contract drift. The target registry is already `github-pages` \| `standard-site`. |
| Doctor | **Internal kernel only** — `src/doctor.zig` audits a rendered snapshot. No public `boris doctor` command. The old design note was retired; this row is the remaining card. |

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
./zig-out/bin/boris plan --profile boris.json
./zig-out/bin/boris nostr plan --profile PATH
# echo -n '<hex-or-nsec>' | ./zig-out/bin/boris nostr sign --plan PLAN --key-stdin --out BUNDLE
# ./zig-out/bin/boris nostr publish --plan PLAN --bundle BUNDLE --out REPORT

./zig-out/bin/boris standard-site                   # family list
./zig-out/bin/boris standard-site plan --profile profiles/standard-site.json

zig build --build-file editor/build.zig
zig build --build-file tools/search-index/build.zig test
zig build --build-file tools/migration-lab/build.zig test
zig build test-layout-hostile
```

## Active roadmap

Completed afterparty work (relationship classification, Touch Atlas, Proof Pack,
Pages, Standard.site first-tester path, editor conformance sweeps, RAG working
context, test-throughput audit) is **done**. It is not relisted as upcoming.

| Order | Card | State | Boundary / verification |
|---:|---|---|---|
| 1 | Release-state decision | **Decided — pending release context** | Preserve the erroneous v0.8.0 tag; next identifier is v0.8.1. Do not tag until release context is complete. Then run [`release-gate.sh`](../scripts/release-gate.sh). |
| 2 | Archive browser review | **Next evidence pass** | Inspect the retained fixture at 375px, 768px, and 1440px plus keyboard traversal; record actual evidence before changing layout behavior. |
| 3 | Archive presentation fixes | **Evidence-gated** | Small, framework-free HTML/CSS or layout fixes only after the browser review finds a reproducible issue. |
| 4 | Migration-guide review findings | **Evidence complete — review remains** | Review the retained MDX/frontmatter/link/asset findings and four generated-site missing routes before claiming a clean migration. |
| 5 | Source-RAG publication safety | **Dependent on evidence** | Make only a tested, narrowly justified staging/cleanup improvement. |
| 6 | Standard.site HTML verify emit | **Open [#533](https://github.com/drawmeanelephant/boris/issues/533)** | Production HTML must emit verification surfaces before `verify` against a real `dist/` can pass. |
| 7 | Nostr as a verified target | **CLI shipped; verified-target work remains [#454](https://github.com/drawmeanelephant/boris/issues/454)** | plan/sign/publish exist. Location adapter, Proof Pack, and live-smoke are not implied. |
| 8 | Cloudflare embedding | **Open [#300](https://github.com/drawmeanelephant/boris/issues/300) / [#301](https://github.com/drawmeanelephant/boris/issues/301)** | Container-backed native builds and freestanding Wasm. Outside the static-target matrix. |

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
  deterministic [`fragment inventory`](changelog.d/INVENTORY.md). The inventory
  no longer matches the on-disk count (200+ fragments). That is release-owner
  work, not an invitation to cut v0.8.1 from a docs PR.
- The release gate now correctly accepts the validated four-level nested hierarchy fixture.

## Product boundaries that remain deliberate

| Not now | Reason |
|---|---|
| Subprocess Markdown rendering | Oliver is consumed as a native Zig module (never a subprocess). |
| Node/React/Astro/Next as the compiler | Boris itself is the Zig compiler. |
| Full YAML frontmatter or arbitrary MDX | The author grammar and registered components are intentionally closed. |
| Embedded HTTP server as product architecture | Serve generated `dist/` with any ordinary static host. The editor host is a local authoring surface, not a public app server. |
| Universal migration conversion | Migration labs are review-first, bounded developer tools. |
| Speed or cross-OS-byte-identity claims | Measure the specific workload and platform first. |
| Silently deleting targets or the editor | Demotion in the story is not removal. Removal is a different issue. |

## Risk and environment notes

- HTML/IR/RAG publication uses staging and rename where supported; cross-volume
  whole-tree atomicity is not claimed.
- Symlink tests may skip when the host denies symlink creation.
- Default HTML assumes trusted author input because raw HTML passes through (unchanged raw-HTML policy).
- `--jobs` is bounded HTML rendering; graph discovery, resolution, and commit
  phases remain coordinated for deterministic output.
- Generated directories (`dist/`, `rag/`, `source-rag/`, caches, and temporary
  release-gate output) are not source-of-truth or review currency.
- Standard.site app passwords grant broad account write. Use a dedicated
  non-personal test identity. Never put the password on argv, in the profile,
  in the environment, in git, or in evidence.

## Documentation map

| Document | Use it for |
|---|---|
| [`README.md`](../README.md) | Product outcomes and quick start |
| [`docs/contracts/`](contracts/) | Normative compiler and artifact behavior |
| [`docs/contracts/publication-model.md`](contracts/publication-model.md) | Canonical ownership of document facts, publication facts, migration provenance, projections, and verification claims |
| [`docs/contracts/publication-platforms.md`](contracts/publication-platforms.md) | Target registry and verified-target adapter seam |
| [`CHANGELOG.md`](../CHANGELOG.md) | Released-history record |
| [`docs/changelog.d/`](changelog.d/) | Pending release fragments |
| [`docs/MIGRATION.md`](MIGRATION.md) | Bounded author migration workflow |
| [`docs/authoring-spine.md`](authoring-spine.md) | Teaching path from `boris init` to publish + verify |
| [`tools/migration-lab/README.md`](../tools/migration-lab/README.md) | Standalone migration-lab commands |
| [`tools/search-index/README.md`](../tools/search-index/README.md) | Rendered search tool |
| [`docs/github-pages.md`](github-pages.md) | GitHub Pages setup, location model, workflow, and evidence boundary |
| [`docs/standard-site.md`](standard-site.md) | Standard.site first-tester path |
| [`docs/RELEASE-GATE.md`](RELEASE-GATE.md) | Mechanical ship checks |
| [`AGENTS.md`](../AGENTS.md) | Repository policy and agent constraints |
| [`content/`](../content/) | Compiled public documentation site (Oliver-rendered) |
| [`docs/SOURCE-MAP.md`](SOURCE-MAP.md) | Where `src/` clusters live. Not a function catalog. |
