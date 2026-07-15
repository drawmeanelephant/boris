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

1. **Load** — Discover case-sensitive `.md` / `.mdx` under `content/`. The
   content-root directory `includes/` is **not** scanned as pages.
2. **Roll** — Parse closed frontmatter; tokenize Aside components; resolve roles
   and parents; validate the Trunk/Satellite graph.
3. **Ignite** — On the HTML path: expand includes, rewrite wiki-links by entity
   id, then render with ApexMarkdown Unified and assemble layout markers
   (`{{content}}`, optional `{{nav}}` / `{{breadcrumb}}` / `{{title}}` /
   `{{toc}}`). Or emit IR / RAG when those modes are selected.
4. **Reset** — Free per-page scratch (HTML path) so the next page stays lean.

## Graph-aware HTML chrome

When the layout includes `{{nav}}`, the site forest comes from the **same**
frozen graph used for IR/RAG. Invalid parents fail the **HTML** build too
(exit 1). In-page `{{toc}}` is built from rendered heading ids (`h1`–`h3`).

## Includes and wiki-links

Authors can share fragments and link by entity id. Both run **before** Apex on
the HTML path; nothing expands inside fenced code.

```markdown
{{include includes/authoring-note.md}}

Read [[guides/trunk-satellite]] or [[reference/frontmatter|closed frontmatter]].
```

{{include includes/authoring-note.md}}

Live links (entity ids, optional labels): see
[[guides/trunk-satellite|Trunk vs Satellite]], [[guides/asides|Asides]], and
[[reference/frontmatter]].

## Guides in this section

| Guide | Topic |
|-------|--------|
| [[guides/trunk-satellite|Trunk and Satellite]] | Roles, `parent`, validation rules |
| [[guides/asides|Asides]] | Constrained callouts in document order |
| [[guides/apex-markdown|Apex Markdown]] | Unified feature showcase |
| [[guides/cli-and-modes|CLI and modes]] | HTML / IR / RAG (parent: Getting Started) |
| [[guides/rag-export|RAG export]] | `boris --rag` corpus shape |

Author keys cheat-sheet: [[reference/frontmatter|Frontmatter reference]].
