---
title: Boris Documentation
status: published
tags: [home, zig]
---

<p class="eyebrow">Boris documentation</p>

# Build a site you can understand later

Write Markdown. Make its relationships explicit. Boris turns that one source
tree into a dependable static site—and, when useful, structured IR, a RAG
corpus, an AI Context Bundle, and `llms.txt`.

<p class="home-actions"><a href="start-here.html">Build your first site</a><a href="learn.html">Learn the content model</a><a href="reference.html">Look up a rule</a></p>

Boris is a local Zig documentation compiler for people who want a durable way
out of framework churn, opaque content silos, and “the navigation probably
works” publishing. It is not a hosted CMS or a JavaScript site stack.

<Aside kind="info">

**A content tree with receipts.** Boris checks parent relationships,
wiki-link targets, headings, and includes before it publishes. Invalid structure
fails with a diagnostic instead of quietly becoming broken navigation.

</Aside>

## Pick the path you are on

| You are here to… | Start here |
|---|---|
| Publish a first documentation site | [[start-here|Start Here]] — the short, working path |
| Write and organize pages | [[learn|Learn]] — content, Markdown, navigation, and outputs |
| Find an exact command or rule | [[reference|Reference]] — authoring, diagnostics, CLI, and outputs |
| Understand the compiler’s boundaries | [[architecture|Architecture]] — graph, pipeline, and design choices |
| Evaluate or migrate an existing site | [[guides/migration|Migration guide]] — a bounded, review-first workflow |

## One source tree, several useful outputs

| You need | Boris gives you |
|------|-------------------|
| A site readers can open anywhere | Static HTML under `dist/`, with navigation, TOC, assets, Asides, and Details |
| Structure you can trust | A validated Trunk/Satellite graph, includes, heading targets, and diagnostics |
| Data for tools and automation | JSON IR with typed edges and a reverse index |
| Better AI grounding | Deterministic RAG, Context Bundle, and `llms.txt` outputs with provenance |
| A path off an old site | A bounded migration workflow that preserves review items instead of guessing them away |

## Small by design, not by accident

The compiler stays close to the work: one Zig binary, ApexMarkdown Unified
called in-process, HTML written directly to disk, and no required client
runtime. The HTML path supports incremental rebuilds, watch mode, bounded
parallel page rendering, and isolated build targets when the site needs them.

The teaching rhythm is **Load → Roll → Ignite → Reset**: discover the content,
resolve the graph, emit a chosen output, then clear page scratch and move on.
The metaphor is optional; the contracts and generated artifacts are not.

This site is Boris dogfood. Its public documentation lives in the same
`content/` tree it compiles: ordinary Markdown, real includes, wiki-links,
parent/child navigation, and deliberately closed components. Repository
contracts remain the maintainer-grade source for exact compatibility rules;
the reference section here turns those rules into a usable authoring guide.
