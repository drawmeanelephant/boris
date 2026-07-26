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

## Choose your next step

| Page | What you’ll learn |
|------|-------------------|
| [[start-here|Start Here]] | Install Boris, build the sample site, and learn the essential commands |
| [[learn|Learn]] | Understand the content model, Markdown authoring, and output workflow |
| [[reference|Reference]] | Look up frontmatter, diagnostics, and precise compiler behavior |
| [[architecture|Architecture]] | Follow the graph, pipeline, IR, RAG, and design boundaries |
| [[archive|Archive]] | Browse Build Week history and evidence-bound agent field notes |

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
