---
rag_id: graph/relations
rag_path: graph/relations.md
category: graph
tags: [graph, hierarchy, trunk, satellite]
related:
  - graph/entity-catalog.md
---

# Graph relations (parent hierarchy)

Edges come from page frontmatter `parent: <entity-id>`. Hubs and direct child
lists are ordered by `entity_id`; parent chains may be nested but must remain
acyclic. Invalid graphs never publish this file (shared `graph.validate` must
pass first).

## Hierarchy hubs

### `empty-no-fm` — empty-no-fm

- Root RAG: `content/pages/empty-no-fm.md`
- Children:
  - *(none)*

### `hierarchy-great-grandchild` — Hierarchy Great-Grandchild

- Parent RAG: `content/pages/hierarchy-great-grandchild.md`
- Children:
  - *(none)*

### `hierarchy-leaf` — Hierarchy Leaf

- Parent RAG: `content/pages/hierarchy-leaf.md`
- Children:
  - `hierarchy-great-grandchild` (Hierarchy Great-Grandchild) → `content/pages/hierarchy-great-grandchild.md`

### `hierarchy-mid` — Hierarchy Mid

- Parent RAG: `content/pages/hierarchy-mid.md`
- Children:
  - `hierarchy-leaf` (Hierarchy Leaf) → `content/pages/hierarchy-leaf.md`

### `hierarchy-trunk` — Hierarchy Trunk

- Root RAG: `content/pages/hierarchy-trunk.md`
- Children:
  - `hierarchy-mid` (Hierarchy Mid) → `content/pages/hierarchy-mid.md`

### `home` — Home Trunk

- Root RAG: `content/pages/home.md`
- Children:
  - `satellite-child` (Child Satellite) → `content/pages/satellite-child.md`

### `nested/deep/page` — Nested Deep Page

- Root RAG: `content/pages/nested/deep/page.md`
- Children:
  - *(none)*

### `satellite-child` — Child Satellite

- Parent RAG: `content/pages/satellite-child.md`
- Children:
  - *(none)*

## Edge list (machine-friendly)

```
parent	hierarchy-great-grandchild	->	hierarchy-leaf
parent	hierarchy-leaf	->	hierarchy-mid
parent	hierarchy-mid	->	hierarchy-trunk
parent	satellite-child	->	home
```
