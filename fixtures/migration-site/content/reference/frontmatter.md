---
title: Frontmatter reference
parent: reference
status: published
tags: [reference, frontmatter]
---

# Frontmatter reference

Closed set — **exactly five keys**:

```text
id | title | parent | status | tags
```

## Field summary

| Key | Required | Notes |
|-----|----------|-------|
| `id` | no | Overrides path-derived id; same shape rules |
| `title` | no | ≤ 512 UTF-8 bytes |
| `parent` | no | Entity id of a **Trunk**; presence ⇒ Satellite |
| `status` | no | `draft` \| `published` \| `archived` only |
| `tags` | no | `[tag1, tag2]` flow list only |

## Not accepted

- `parentEntry`, `parent_entry`, `aliases`, layout keys, nested YAML
- Single-quoted scalars, block scalars `|` / `>`, anchors

## See also

[[guides/authoring-frontmatter]] · [[concepts/parent-keys]]
