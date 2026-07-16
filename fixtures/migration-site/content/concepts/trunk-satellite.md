---
title: Trunk and Satellite
parent: concepts
status: published
tags: [concepts, graph]
---

# Trunk and Satellite

Boris models documentation as a **forest**:

- **Trunk** pages are roots (no `parent`).
- **Satellite** pages name exactly one Trunk via `parent: <entity-id>`.

## Contoso forest (this fixture)

```text
index
guides
  ├─ guides/getting-started
  ├─ guides/installation
  ├─ …
  └─ guides/deep/nested/path/note
reference
  └─ …
concepts
  └─ …
ops
  └─ …
cookbook
  └─ …
special/CaseDemo          (trunk — demos stand alone)
special/cafe-notes        (trunk)
```

Landing pages such as `guides.md` are **Trunks**. Child guides are
**Satellites** of `guides`, not of each other.

## HTML nav

When the layout includes site nav markers, the sidebar forest is generated from
this same graph. Broken parents fail the HTML build — not only IR mode.
