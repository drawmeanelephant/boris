---
rag_id: system/trunk-and-satellite
rag_path: system/03-trunk-and-satellite.md
category: system
tags: [graph, trunk, satellite, parentEntry, relations]
related:
  - system/02-data-model-page.md
  - system/04-components-and-admonitions.md
  - graph/entity-catalog.md
  - graph/relations.md
---

# Trunk and Satellite graph model

Boris does **not** treat the content tree as a flat list of unrelated files. It uses a **Trunk and Satellite** relational model.

## Definitions

- **Trunk** — a canonical page with no `parentEntry`. It is a primary document in the graph (long-form narrative, hub page, reference).
- **Satellite** — a page whose frontmatter declares `parentEntry: <trunk-entity-id>`. It attaches to that trunk as supporting material (tips, errata, deep-dives, sidebars).

## Foreign key

```yaml
parentEntry: guides/intro
```

The value must match the trunk’s `entity_id` (path without extension), not the HTML URL and not a free-form title.

## Role detection

```text
if parentEntry is set → role = "satellite"
else                  → role = "trunk"
```

## Why this exists

Folder hierarchy alone cannot express “this tip pack belongs to that guide” when files live as siblings or in parallel trees. Explicit foreign keys make the graph LLM-readable and compile-time queryable.

## Example

| File | entity_id | parentEntry | role |
|------|-----------|-------------|------|
| `content/guides/intro.md` | `guides/intro` | (none) | trunk |
| `content/guides/intro-tips.md` | `guides/intro-tips` | `guides/intro` | satellite |
| `content/index.md` | `index` | (none) | trunk |

## What is *not* a graph node

Asides / admonitions are **in-page content**, not Trunk or Satellite entities. They do not get separate entity ids or RAG fragment documents.

## Retrieval hints for LLMs

When answering questions about a guide:

1. Load the trunk segment under `rag/content/pages/...`
2. Load satellites whose `parent_entry` equals that trunk `entity_id` (see `graph/relations.md`)
3. Read inlined asides from those page Bodies (`:::kind` blocks) — not a separate tree
