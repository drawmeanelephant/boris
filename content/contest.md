---
id: contest
title: Boris at Build Week
status: published
tags: [build-week, overview, dogfood]
---

# Boris at Build Week

Boris is a local Zig documentation compiler for people who want Markdown to
be more than a folder full of files. It validates the content graph, builds a
static HTML site by default, and can emit structured IR, RAG, Context Bundles,
and `llms.txt` from the same source tree.

This section is the short version for a curious judge, contributor, or future
owner: what the project can do today, how it was made, and where it remains
deliberately strict.

<Aside kind="info">

**The useful promise is modest.** Boris is not a hosted CMS, a JavaScript
framework, or a universal one-click importer. It is a local compiler with
explicit contracts, deterministic output, and migration tools that report
their uncertainty instead of pretending it disappeared.

</Aside>

## Pick a path

| If you have five minutes | Read |
|---|---|
| What is genuinely shipping? | [[contest/what-shipped|What shipped]] |
| How did the human/AI collaboration work? | [[contest/how-it-was-built|How Boris was built]] |
| What comes out of one Markdown tree? | [[contest/the-pipeline|The output pipeline]] |
| What did the project intentionally refuse to become? | [[contest/what-we-cut|What Boris cuts on purpose]] |

## The human story is part of the artifact

The build was continuously human-steered with GPT-5.6 and Codex: architecture,
scope cuts, review standards, and merge decisions were treated as product work,
not decoration after generation. The project also keeps an evidence-bound
[[agents|Agent Field Notes]] section: named worker stories, external-tool
credits, and uncertainty are kept separate on purpose.

That choice matters because the compiler is itself built around the same idea:
make the graph and its boundaries inspectable before asking a machine—or a
human—to trust them.
