---
title: Boris Docs Compiler
status: published
tags: [home, zig]
---

# Welcome to Boris

Boris is a **Zig documentation compiler**: Markdown in, validated Trunk/Satellite
graph, HTML site out (default). Same binary also emits JSON IR or a RAG pack
when you ask.

Teaching beat (narrative, not CLI flags): **Load → Roll → Ignite → Reset**.

<Aside kind="info">

**Product v0.3.0.** Bare `boris` builds HTML under `dist/` with **ApexMarkdown
Unified**. The default layout ships graph-aware **site nav**, **breadcrumb**,
and an in-page **table of contents** — look at the chrome around this page.
Includes and wiki-links expand on this path before Apex runs.

</Aside>

## Why Boris?

- **One Zig binary** — no Node SSG stack, no bundler, no React runtime for the compile.
- **Strict content graph** — Trunk/Satellite parents fail loud (exit 1) instead of shipping broken links.
- **Real Markdown** — ApexMarkdown Unified in-process (tables, footnotes, callouts, …).
- **Lean HTML path** — layout + body stream to disk; optional `--incremental`, `--watch`, `--jobs N`.

## Start here

| Page | What you’ll learn |
|------|-------------------|
| [[getting-started|Getting started]] | Build Boris, first site, three modes |
| [[guides/cli-and-modes|CLI and modes]] | HTML default vs `--out` vs `--rag` |
| [[guides/overview|Content model]] | Pipeline + Trunk/Satellite |
| [[guides/apex-markdown|Apex showcase]] | Tables, footnotes, math, callouts, IAL, … |
| [[reference/frontmatter|Frontmatter reference]] | Closed author keys |

This tree under `content/` is **dogfood**: it is the sample docs site compiled by
the product itself. Real includes and wiki-links appear on pages such as
[[getting-started]] and [[guides/overview]].
