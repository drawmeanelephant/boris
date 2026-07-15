---
title: Content Model Overview
status: published
tags: [guides, architecture]
---

# Content Model & Pipeline

Boris treats your docs as a **validated graph**, not a flat file dump. Pages are
**Trunks** (roots) or **Satellites** (children of a trunk). Frontmatter is a
**closed key grammar** — not full YAML.

## Pipeline: Load → Roll → Ignite → Reset

1. **Load** — Discover case-sensitive `.md` / `.mdx` under `content/`.
2. **Roll** — Parse closed frontmatter; tokenize Aside components; resolve roles
   and parents; validate the Trunk/Satellite graph.
3. **Ignite** — Render with ApexMarkdown Unified; assemble layout markers
   (`{{content}}`, optional `{{nav}}` / `{{breadcrumb}}` / `{{title}}` / `{{toc}}`);
   or emit IR / RAG when those modes are selected.
4. **Reset** — Free per-page scratch (HTML path) so the next page stays lean.

## Graph-aware HTML chrome

When the layout includes `{{nav}}`, the site forest comes from the **same**
frozen graph used for IR/RAG. Invalid parents fail the **HTML** build too
(exit 1). In-page `{{toc}}` is built from rendered heading ids (`h1`–`h3`).

## Guides in this section

| Guide | Topic |
|-------|--------|
| [Trunk and Satellite](trunk-satellite.html) | Roles, `parent`, validation rules |
| [Asides](asides.html) | Constrained callouts in document order |
| [Apex Markdown](apex-markdown.html) | Unified feature showcase |
| [CLI and modes](cli-and-modes.html) | HTML / IR / RAG (parent: Getting Started) |
| [RAG export](rag-export.html) | `boris --rag` corpus shape |

Author keys cheat-sheet: [Frontmatter reference](../reference/frontmatter.html).
