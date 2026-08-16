# `docs/boris/` — source dossier snapshot

**As of:** 2026-08-16

This tree is **not** the product documentation. It is not a contract. It is
not a current map of `src/`.

It is a frozen analytical **source dossier**: four Markdown pages per
documented module (overview, surface-and-execution, evidence-and-cases,
review-state), written against an earlier compiler shape. The link guard
excludes the whole tree on purpose (`scripts/doc-links-exclusions.txt`).
The compiled site lives under [`content/`](../../content/). Normative
behavior lives under [`docs/contracts/`](../contracts/).

## The cheap truth

| Fact | Number |
|---:|---|
| Markdown files under `docs/boris/src/` | 177 |
| `src/*.zig` modules today | 103 |
| Modules with a four-page dossier | 44 |
| Modules with **no** dossier | 59 |
| Valid `<!-- BORIS-SOURCE-DOC BEGIN path="src/…">` claims | ~0 |

`boris-docs-maintenance scan` (2026-08-16) counted 173 files as
`source_dossier` by path and **92** `src/*.zig` files as
`source_without_dossier`. The prose exists. The claim markers that would
bind a page to a source file were never finished. Do not treat a folder
named `cli/` as proof that `src/cli.zig` still matches the page.

## What is covered

The 44 dossiers are the pre-publication-platform compiler core: parse,
graph, render, HTML chrome, IR/RAG/Context/`llms`, watch, cache, theme,
layout, and a handful of test roots. The index is
[`src/index.md`](src/index.md).

Typical staleness, from pages that still compile as prose:

- `src/cli.zig` overview still says five output modes and three commands.
  Afterparty has `validate`, `watch`, `plan`, and `standard-site`.
- `src/main.zig` overview still dispatches IR / RAG / context / llms / HTML
  plus `check` / `impact`. It does not know about Atmosphere, Pages
  adapters, RSS, sitemap, search, or `boris init`.

Those pages can be useful as archaeology. They are not a briefing.

## What is missing

The undocumented half of `src/` is the publisher-platform era. Do not
grow this tree to “catch up.” Contracts already own that surface.

Undocumented on purpose until someone files a real need:

AT Protocol / Standard.site
: `atproto_*.zig`, `standard_site*.zig`

Publication evidence and targets
: `publication_*.zig`, `github_pages.zig`, `artifact_*.zig`

Other afterparty modules
: `nostr.zig`, `rss.zig`, `sitemap.zig`, `search_index.zig`, `init.zig`,
  `doctor.zig`, `cooklang_seam.zig`, `preview_server.zig`, and the rest of
  the 59-file gap listed in [`src/index.md`](src/index.md)

## How to use this tree

1. Need current behavior? Open the contract, then the `.zig` file.
2. Need a historical reading of an old module? Start at that module’s
   `overview.md`. Believe a sentence only after you see it in source.
3. Need to invent 59 new four-page dossiers? Don’t. That is the
   high-intensity, low-reward path. Write a contract or a field note
   instead.
4. Need a mechanical inventory? Run
   `zig build --build-file tools/docs-maintenance/build.zig run -- scan`.
   The report is generated. This README is not.

## Sibling swamp

[`docs/tools/`](../tools/) is the same species for standalone tools
(migration-lab, source-rag). Same rule: analytical snapshot, not the
operator path. Operator docs are the tool READMEs and
[`docs/MIGRATION.md`](../MIGRATION.md).
