# Capability matrix — v0.8 snapshot (archived)

Archived **2026-08-21** from [`docs/STATUS.md`](../STATUS.md) per
[issue #692](https://github.com/drawmeanelephant/boris/issues/692).
`STATUS.md` is now a phase banner + pointer table (<80 lines).
Git history preserves the full file; this snapshot keeps the v0.8
capability tables reachable without restoring the whole document.

> Source revision: `docs/STATUS.md` as of 2026-08-21, `v0.8.1 candidate` /
> `boris/0.8.1`, IR `0.2.0`, afterparty tip PR #676.

## Identity

Boris is a **graph-native publication compiler** with multiple targets
(publisher platform, [#538](https://github.com/drawmeanelephant/boris/issues/538)).

| Layer | What it is |
|---|---|
| Compiler core | One Zig binary. Closed frontmatter. Oliver in-process. Fail-loud graph. Default CLI writes `dist/`. |
| Publication targets | A registry. GitHub Pages and Standard.site are verified. Nostr plan/sign/publish is shipped and is not a verified target. |
| Evidence chain | `artifacts.json` → `checks.json` → `claims.json` → `touches.json` → Proof Pack. |
| Editor | In-tree authoring surface. Compiler-backed. Not a second stack. |
| Labs | Standalone migration and source-RAG tools. In the repo story. Not runtime dependencies. |
| Parked | Cloudflare Containers (#300) has an official hosted-runner example; Freestanding Wasm (#301) has an example Worker host. Neither is a verified target. |

Normative ownership: [`publication-model.md`](../contracts/publication-model.md) and
[`publication-platforms.md`](../contracts/publication-platforms.md).

## What works — Compiler core

| Capability | Current state |
|---|---|
| Default site build | **Done** — `boris` writes HTML to `dist/`. |
| Markdown rendering | **Done** — Oliver (pinned in `build.zig.zon`) through `src/render.zig`: CommonMark + GFM tables + heading ids/IAL, footnotes, definition lists, strikethrough. |
| Content graph | **Done** — closed frontmatter, validated Trunk/Satellite hierarchy with arbitrary finite acyclic parent chains, includes, wiki links, and heading targets. |
| No-publication validation | **Done** — `boris validate` reuses the canonical HTML prepublication compiler path and writes no target, cache, search, or evidence artifacts. `validate --watch` repeats that preflight as a zero-write daemon with `--watch-json` events and per-cycle `--report` rewriting. |
| HTML navigation and layouts | **Done** — graph-backed nav, breadcrumbs, TOC, closed layout slots, assets, layout rules, incremental/watch/jobs, isolated targets, opt-in XML sitemap. |
| Machine outputs | **Done** — IR 0.2, RAG (working-context packs + `--complete` corpus, schema 2), Context Bundles, `llms.txt`, deterministic RSS 2.0; semantic relations retain their documented conditional IR 0.3 artifacts. |

## What works — Publication targets

| Target | Current state |
|---|---|
| GitHub Pages | **Shipped and verified** — normalized project/root/custom-domain identity, exact public artifact boundary, retained target-local evidence, optional bounded post-deploy observer. Operator path: [`github-pages.md`](../github-pages.md). |
| Standard.site / AT Protocol | **Shipped for first testers** — offline plan/records/verify, opt-in app-password login, one-shot publish, recorded passing bsky.social live smoke. Browser OAuth is implemented; bsky.social does not grant `site.standard.authFull` (exit 6). Operator path: [`standard-site.md`](../standard-site.md). |
| Publication evidence | **Done** — artifacts → checks → claims → Touch Atlas → Proof Pack, staged, deterministic. |
| Nostr NIP-23 | **CLI shipped; stays off the verified-target seam** — `boris nostr plan` / `sign` / `publish` (BIP-340, bounded RFC-6455, per-relay verdict). Plan emits NIP-19 `naddr` / `npub`. `boris --profile` emits `nostr:naddr` alternate links on eligible pages. Recorded first-tester live-smoke fixture (optional evidence, not a gate). Relays are not a host, so there is no location adapter, Proof Pack, or live-smoke gate. Guide: [`content/guides/nostr-publication.md`](../../content/guides/nostr-publication.md). |

## What works — Editor

| Capability | Current state |
|---|---|
| Boris Editor | **First-class authoring surface** — local host (`lib/types\|api\|utils` + 11 components + dialogs, `App.svelte` ~250 orchestrator after [#670](https://github.com/drawmeanelephant/boris/issues/670) slices 1–6 [#671](https://github.com/drawmeanelephant/boris/pull/671)–[#676](https://github.com/drawmeanelephant/boris/pull/676)), schema- and graph-aware completion, compiler-backed problems (via a long-lived `validate --watch` daemon when the compiler supports it, one-shot fallback otherwise), live preview of committed `dist/`, publication plan over `boris plan --profile`. Recipe scaling asks `boris recipe-scale`; the editor does not multiply amounts. Stale artifacts stay in-shell. File and list bounds (8 MiB / 50,000 files) are named. Overlapping saves are serialized; corrupt recovery snapshots are skipped. Large file lists stay bounded and filterable. A host crash flushes recovery and the tab names Restart boris-editor. External disk edits are probed while a file is open. Open, save, preview, and completion waits are named with elapsed time. Keyboard checklist for [#418](https://github.com/drawmeanelephant/boris/issues/418) M10 is in CI (112/112 Playwright, `check-key-hints` 24 hints — re-verified on `afterparty` `5021261` in [#679](https://github.com/drawmeanelephant/boris/issues/679)); spoken Voice Control is not claimed — see [#677](https://github.com/drawmeanelephant/boris/issues/677). Guide: [`content/guides/editor.md`](../../content/guides/editor.md). |

## What works — Labs

| Capability | Current state |
|---|---|
| Migration laboratories | **Done as bounded developer tools** — read-only review, conversion aids, relationship candidates, theme materialization. They do not widen Boris author grammar. |
| Relationship inventory + classification | **Done** — schema-v2 inventory and exact eligible-key classification (`inventoried`, `ambiguous`, `absent`, `invalid`). No automatic relation emission. |
| Migration-guide executable pass | **Evidence complete** — 69-page Starlight dogfood converted and compiled; human review remains for preserved/stripped/manual-review findings. |
| Source-RAG ergonomics | **Measured** — no behavior change justified by the snapshot. |
| Archive-layout evidence | **Viewport evidence complete; accessibility review remains** — fixture, black-box audit, link audit, and real-browser viewport measurements at 375/768/1440 px plus a programmatic focus-order walk; trusted-key traversal, screen-reader order, and actual `:focus-visible` behavior remain open. The review's one reproducible issue (table pages overflowing the viewport at phone widths) was fixed in [#667](https://github.com/drawmeanelephant/boris/pull/667). Evidence: [`BROWSER-REVIEW.md`](../contracts/fixtures/archive-layout-audit/BROWSER-REVIEW.md). |
| Twenty Twenty materialization | **Done** — bounded GPL-evidenced archaeology → reviewed ledger → static materialization → Boris build → link audit. |
| Filed.fyi / theme dogfood reports | **Retired** — long-form `docs/dogfood/` writeups deleted. Facts stay in this table. Human review findings for the Starlight migration-guide pass remain on the roadmap. |

## Parked / open

| Card | State |
|---|---|
| Cloudflare Containers (#300) | **Example runner shipped.** `boris-job-runner` execs native `boris` once (`--once` / `--listen`). Official Worker+Container example under `examples/cloudflare-container/`. Not a verified target. |
| Freestanding Wasm (#301) | Cards M0–M7 exist. Example Worker host is [`hosts/cloudflare-worker/`](../../hosts/cloudflare-worker/). Not a `publication.target`. #301 closed with a live Cloudflare smoke and isolate-peak measurements recorded in the worker README; RAG/context not in the first embed profile. |
| Doctor | **Internal kernel only** — `src/doctor.zig` audits a rendered snapshot. No public `boris doctor` command. The old design note was retired; this row is the remaining card. |
| Nostr verified-target extras ([#584](https://github.com/drawmeanelephant/boris/issues/584)) | Location adapter / registry membership **declined**. Proof Pack and a live-smoke **gate** stay parked unless a product reason appears. |

## Common commands (at snapshot)

```bash
zig build
zig build test
./scripts/release-gate.sh

./zig-out/bin/boris-job-runner --once --archive IN.tar --result-json OUT.json
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
./zig-out/bin/boris recipe-scale --input DIR --id PAGE --factor TEXT --cooklang
./zig-out/bin/boris recipe-scale --input DIR --id PAGE --servings N --cooklang
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

## Active roadmap (at snapshot)

| Order | Card | State | Boundary / verification |
|---:|---|---|---|
| 1 | Release-state decision | **Decided — pending release context** | Preserve the erroneous v0.8.0 tag; next identifier is v0.8.1. Do not tag until release context is complete. Then run [`release-gate.sh`](../../scripts/release-gate.sh). |
| 2 | Migration-guide review findings | **Evidence complete — review remains** | Review the retained MDX/frontmatter/link/asset findings and four generated-site missing routes before claiming a clean migration. |
| 3 | Source-RAG publication safety | **Dependent on evidence** | Make only a tested, narrowly justified staging/cleanup improvement. |
| 4 | Standard.site HTML verify emit | **Shipped [#569](https://github.com/drawmeanelephant/boris/pull/569)** | `boris --profile` emits verification surfaces from the HTML build. |
| 5 | Nostr as a verified target | **Decided — stays off the seam** | Location adapter / registry membership declined. See [`publication-platforms.md`](../contracts/publication-platforms.md). Proof Pack and a live-smoke **gate** stay parked on [#584](https://github.com/drawmeanelephant/boris/issues/584) and are not implied. |
| 6 | Cloudflare embedding | **Both example surfaces shipped: #301 Worker host + #300 hosted runner** | Example Worker host is [`hosts/cloudflare-worker/`](../../hosts/cloudflare-worker/); hosted `boris-job-runner` + Worker example under `examples/cloudflare-container/`. Neither is in `publication.target`. |

Shipped rows (4–6) are retained here for history; the slim `STATUS.md` lists only pending items.

## Product boundaries that remain deliberate (at snapshot)

| Not now | Reason |
|---|---|
| Subprocess Markdown rendering | Oliver is consumed as a native Zig module (never a subprocess). |
| Node/React/Astro/Next as the compiler | Boris itself is the Zig compiler. |
| Full YAML frontmatter or arbitrary MDX | The author grammar and registered components are intentionally closed. `servings` / `serves` / `yield` are the one Cooklang-convention exception ([frontmatter.md](../contracts/frontmatter.md)); they are not a crack for other YAML keys. |
| Embedded HTTP server as product architecture | Serve generated `dist/` with any ordinary static host. The editor host is a local authoring surface, not a public app server. |
| Universal migration conversion | Migration labs are review-first, bounded developer tools. |
| Speed or cross-OS-byte-identity claims | Measure the specific workload and platform first. |
| Silently deleting targets or the editor | Demotion in the story is not removal. Removal is a different issue. |

## Risk and environment notes (at snapshot)

- HTML/IR/RAG publication uses staging and rename where supported; cross-volume whole-tree atomicity is not claimed.
- Symlink tests may skip when the host denies symlink creation.
- Default HTML assumes trusted author input because raw HTML passes through (unchanged raw-HTML policy).
- `--jobs` is bounded HTML rendering; graph discovery, resolution, and commit phases remain coordinated for deterministic output.
- Generated directories (`dist/`, `rag/`, `source-rag/`, caches, and temporary release-gate output) are not source-of-truth or review currency.
- Standard.site app passwords grant broad account write. Use a dedicated non-personal test identity. Never put the password on argv, in the profile, in the environment, in git, or in evidence.

Canonical homes after slimming: see [`html-output.md`](../contracts/html-output.md) (staging/rename, `--jobs`, generated dirs), [`validation.md`](../contracts/validation.md) (symlink/no-write), [`oliver-renderer.md`](../contracts/oliver-renderer.md) (trusted HTML), [`atproto-app-password.md`](../contracts/atproto-app-password.md) and [`standard-site.md`](../contracts/standard-site.md) (app-password scope).
