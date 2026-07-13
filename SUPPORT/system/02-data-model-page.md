---
rag_id: system/data-model-page
rag_path: system/02-data-model-page.md
category: system
tags: [page, data-model, frontmatter, entity-id]
related:
  - system/03-trunk-and-satellite.md
  - system/04-components-and-admonitions.md
  - system/01-architecture-pipeline.md
---

# Data model: Page and Frontmatter

The core unit of Boris’s in-memory content database is `Page` (`src/page.zig`).

## Page fields

| Field | Type (concept) | Meaning |
|-------|----------------|---------|
| `source_path` | string | Path relative to `content/` (e.g. `guides/intro.md`) |
| `output_path` | string | Path relative to `dist/` (e.g. `guides/intro.html`) |
| `entity_id` | string | Stable graph key derived from source path without extension (`guides/intro`) |
| `frontmatter` | object | Title, `parentEntry`, extras |
| `raw_source` | string | Full file (when retained) |
| `body_md` | string | Markdown after frontmatter (components may be stripped for tools) |

**Not** a Page field: asides / components. Those exist only as parse-time tokens on the document segment stream (`ParsedPage.segments`). The Page model does not require a fixed component list.

## Entity id rules

- `content/guides/intro.md` → entity id `guides/intro`
- `content/index.md` → entity id `index`
- Extensions `.md` and `.mdx` are stripped the same way
- Entity ids use `/` as hierarchy separators (not flattened)

## Frontmatter

YAML-like block at file start:

```markdown
---
title: Introduction
parentEntry: guides/intro
---
```

Recognized keys:

- `title` — display title
- `parentEntry` (alias `parent_entry`) — **foreign key** to a Trunk entity id
- other keys — stored as extras when parsed for tooling

## Components (parse-time only)

Optional registered blocks such as `<Aside kind="tip">` are tokenized into the ordered segment stream. They:

- render **in place** as part of the page HTML body
- are **not** stored as first-class Page fields
- are **not** separate graph nodes or fragment pages by default

See `system/04-components-and-admonitions.md`.

## PageDb

`PageDb` holds:

- `pages: ArrayList(Page)` — spine allocated with the backing GPA
- `arena` — long-lived arena for path strings and promoted metadata

Scan populates paths only; compile/RAG parse fills relational metadata.
