---
rag_id: graph/relations
rag_path: graph/relations.md
category: graph
tags: [graph, relations, trunk, satellite]
related:
  - graph/entity-catalog.md
---

# Graph relations (Trunk → Satellite)

Edges come from satellite frontmatter `parent: <trunk-entity-id>`.
Hubs and satellite lists are ordered by `entity_id`. Edge list is
ordered by source id then target id. Invalid graphs never publish
this file (shared `graph.validate` must pass first).

## Trunk hubs

### `empty-no-fm` — empty-no-fm

- Trunk RAG: `content/pages/empty-no-fm.md`
- Satellites:
  - *(none)*

### `home` — Home Trunk

- Trunk RAG: `content/pages/home.md`
- Satellites:
  - `satellite-child` (Child Satellite) → `content/pages/satellite-child.md`

### `nested/deep/page` — Nested Deep Page

- Trunk RAG: `content/pages/nested/deep/page.md`
- Satellites:
  - *(none)*

## Edge list (machine-friendly)

```
parent	satellite-child	->	home
```
