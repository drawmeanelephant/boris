---
rag_id: system/overview
rag_path: system/00-overview.md
category: system
tags: [boris, overview, ssg, zig]
related:
  - system/01-architecture-pipeline.md
  - system/02-data-model-page.md
  - system/03-trunk-and-satellite.md
  - system/04-components-and-admonitions.md
---

# Boris overview

Boris is a **Zig static-site compiler for Markdown documentation**: validated content metadata, graph-aware navigation, semantic admonitions, and an explicit extension path for custom components. There is no external JavaScript framework in the critical path: Boris owns the pipeline from raw markdown under `content/` to HTML under `dist/`.

## What Boris is for

- Compile a markdown content tree into a static HTML site
- Model content as a **Trunk and Satellite graph** (relational), not only as folders
- Support ordinary documentation primitives first (headings, lists, code, frontmatter)
- Optionally tokenize a small set of **registered components** (e.g. asides/admonitions) that stay in document order
- Render markdown via a **native C-ABI engine (Apex)** linked in-process
- Keep RAM flat while compiling thousands of pages (Whiteboard arena strategy)
- Emit final HTML with **zero-copy layout splicing** (no giant string concatenation)
- Export an **LLM-friendly RAG corpus** under `rag/` for chat systems (Grok, Gemini, etc.)

## Non-goals

- Boris does **not** spawn a child process per page for markdown (no `ChildProcess` render farm)
- Boris does **not** require Node, React, or a JS bundler to produce HTML
- Boris does **not** invent branded names for ordinary docs features (use Aside, admonition, component)
- Boris does **not** emit standalone fragment pages for normal asides
- The first production shape is a **single-threaded monolith** (stable before concurrency)

## Repository layout (mental model)

| Path | Role |
|------|------|
| `content/` | Author source markdown (+ optional registered components) |
| `layouts/main.html` | Site chrome with a single `{{content}}` splice marker |
| `src/` | Zig compiler pipeline (scan → parse → render → assemble → RAG) |
| `vendor/apex/` | C-ABI markdown engine linked into the Boris binary |
| `dist/` | Generated HTML site |
| `docs/rag/system/` | Curated system knowledge seeds for the RAG exporter |
| `rag/` | Generated LLM-ready corpus (upload this tree) |

## How to run

```bash
zig build          # build the boris binary
zig build run      # compile site to dist/ and export RAG to rag/
zig build rag      # export RAG corpus (runs boris --rag)
zig build test     # unit tests
```

Useful flags:

- `--rag` — export RAG only (skip HTML site compile if you only need the corpus)
- `--no-rag` — compile HTML site without writing `rag/`
- `--rag-dir=PATH` — override RAG output directory (default `rag`)

## One-sentence summary for retrieval

Boris is a Zig SSG that walks `content/` once, builds an in-memory Page graph with Trunk/Satellite relations, renders markdown (and in-page asides) through in-process Apex, streams HTML via layout prefix/suffix writes, and exports a path-segmented markdown RAG pack for LLM chat uploads.
