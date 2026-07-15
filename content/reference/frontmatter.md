---
title: Frontmatter Reference
status: published
tags: [reference, authoring]
---

# Frontmatter Reference

Boris accepts a **closed set** of frontmatter keys. Unknown keys (including
legacy `parentEntry` / `parent_entry`) fail with **`EFRONTMATTER`**.

This is **not** full YAML: no nested maps, multiline scalars, anchors, or
arbitrary keys. Bracket `tags` lists are the only list form.

## Allowed keys

| Key | Required | Value |
|-----|----------|--------|
| `id` | no | Override path-derived entity id |
| `title` | no | Page title (≤512 UTF-8 bytes) |
| `parent` | no | Entity id of parent **Trunk** (satellites only) |
| `status` | no | `draft` \| `published` \| `archived` |
| `tags` | no | `[a, b, "c"]` list form only |

## Examples

### Trunk

```yaml
---
title: My Guide Overview
status: published
tags: [guides]
---
```

Omit `parent`. Entity id defaults to the file path without extension.

### Satellite

```yaml
---
title: Detailed Topic
parent: guides/overview
status: published
---
```

`parent` must name an existing trunk id. No satellite-of-satellite, no cycles.

## Forbidden

| Form | Result |
|------|--------|
| `parentEntry` / `parent_entry` | `EFRONTMATTER` (unknown key) |
| Nested YAML / multiline scalars | `EFRONTMATTER` |
| Extra keys | `EFRONTMATTER` |

RAG export may still *emit* a field named `parent_entry` in catalogs — export
packaging only, never author grammar. See [RAG export](../guides/rag-export.html)
and [Trunk/Satellite](../guides/trunk-satellite.html).
