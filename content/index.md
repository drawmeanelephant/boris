---
title: Boris — The Content Exit Hatch
status: published
tags: [home, zig]
---

# Boris: The Content Exit Hatch

Write Markdown. Validate how the pages relate. Publish a fast static site—and
when you need them, emit structured IR, a RAG corpus, an AI Context Bundle, and
`llms.txt` from the same source tree.

Boris is a local Zig documentation compiler for people who want a durable way
out of framework churn, opaque content silos, and “the navigation probably
works” publishing. It is not a hosted CMS or a JavaScript site stack.

<Aside kind="info">

**A content tree with receipts.** Boris checks parent relationships,
wiki-link targets, headings, and includes before it publishes. Invalid structure
fails with a diagnostic instead of quietly becoming broken navigation.

</Aside>

## One source tree, several useful outputs

| You need | Boris gives you |
|---|---|
| A site readers can open anywhere | Static HTML under `dist/`, with layouts, navigation, TOC, assets, Asides, and Details |
| Structure you can trust | A validated Trunk/Satellite graph, includes, heading targets, and diagnostics |
| Data for tools and automation | JSON IR with typed edges and a reverse index |
| Better AI grounding | Deterministic RAG, Context Bundle, and `llms.txt` outputs with provenance |
| A path off an old site | Bounded Zig migration labs that preserve review items instead of guessing them away |

## Take the short tour

| Page | What you’ll learn |
|------|-------------------|
| [[contest|Boris at Build Week]] | What shipped, how it was built, the pipeline, and the boundaries |
| [[contest/the-pipeline|The output pipeline]] | Markdown to HTML, IR, RAG, Context Bundles, and `llms.txt` |
| [[agents|Agent Field Notes]] | Evidence-bound collaboration stories and credits |
| [[getting-started|Getting started]] | Build Boris and ship your first site |
| [[guides/overview|The content model]] | Trunks, Satellites, validation, and the authoring workflow |

## Small by design, not by accident

The compiler stays close to the work: one Zig binary, ApexMarkdown Unified
called in-process, HTML written directly to disk, and no required client
runtime. The HTML path supports incremental rebuilds, watch mode, bounded
parallel page rendering, and isolated build targets when the site needs them.

The teaching rhythm is **Load → Roll → Ignite → Reset**: discover the content,
resolve the graph, emit a chosen output, then clear page scratch and move on.
The metaphor is optional; the contracts and generated artifacts are not.

This site is Boris dogfood. The pages you are reading are compiled from the
same `content/` tree used in the examples: ordinary Markdown, real includes,
wiki-links, parent/child navigation, and deliberately closed components.
