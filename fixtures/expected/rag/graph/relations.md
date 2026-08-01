---
rag_id: graph/relations
rag_path: graph/relations.md
category: graph
tags: [graph, hierarchy, trunk, satellite]
related:
  - graph/entity-catalog.md
---

# Graph relations (parent hierarchy)

Edges come from page frontmatter `parent: <entity-id>` and represent direct
parent-to-child relationships; nested parent chains are valid when acyclic.
Hubs and direct child lists are ordered by `entity_id`. Edge list is ordered by
source id then target id. Invalid graphs never publish
this file (shared `graph.validate` must pass first).

## Hierarchy hubs

### `empty-no-fm` — empty-no-fm

- Root RAG: `content/pages/empty-no-fm.md`
- Children:
  - *(none)*

### `home` — Home Trunk

- Root RAG: `content/pages/home.md`
- Children:
  - `satellite-child` (Child Satellite) → `content/pages/satellite-child.md`

### `nested/deep/page` — Nested Deep Page

- Root RAG: `content/pages/nested/deep/page.md`
- Children:
  - *(none)*

## Edge list (machine-friendly)

```
parent	satellite-child	->	home
```
