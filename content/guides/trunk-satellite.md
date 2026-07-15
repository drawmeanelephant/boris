---
title: Trunk and Satellite Pages
parent: guides/overview
status: published
tags: [graph, content]
---

# Trunk and Satellite Pages

The content graph has two roles.

## Trunks

A **Trunk** is a top-level node.

- Omit `parent` in frontmatter.
- Example: this site’s `guides/overview` page is a trunk.

## Satellites

A **Satellite** is a direct child of a trunk.

- Set `parent: <trunk-entity-id>`.
- Entity ids default to the path without extension (`guides/overview.md` →
  `guides/overview`). Prefer path-derived ids unless you override with `id:`.

### Example satellite frontmatter

```yaml
---
title: My Satellite Page
parent: guides/overview
status: published
---
```

## Validation (hard errors)

The compiler fails the build (exit **1**) when:

| Rule | Meaning |
|------|---------|
| Missing parent | `parent` id does not exist |
| Self-parent | page parents itself |
| Satellite-of-satellite | parent is not a trunk |
| Cycles | parent chain loops |
| Duplicate ids | two pages share an entity id |

Do **not** put intentionally broken pages under `content/` — use
`fixtures/content/invalid/` or contract fixtures for negative cases.

## How nav uses the graph

Site `{{nav}}` and `{{breadcrumb}}` are derived from the frozen Trunk/Satellite
forest. Changing a title or parent dirties pages that embed the forest when
incremental builds include nav material in fingerprints.

Wiki-links use the same entity-id space as `parent`. A bare link to
[[guides/overview]] resolves to this section’s trunk. See
[[reference/frontmatter|frontmatter reference]] and the
[[guides/overview|content model overview]].
