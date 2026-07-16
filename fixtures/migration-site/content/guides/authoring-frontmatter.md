---
title: Authoring frontmatter
parent: guides
status: published
tags: [guides, frontmatter]
---

# Authoring frontmatter

Boris frontmatter is a **closed grammar**, not full YAML.

## Allowed keys

| Key | Role |
|-----|------|
| `id` | Optional override of path-derived entity id |
| `title` | Page title |
| `parent` | Satellite → Trunk entity id (**only** this key name) |
| `status` | `draft` \| `published` \| `archived` |
| `tags` | Bracket list: `[a, b]` |

## Rejected (common migration traps)

| Incoming key / form | What Boris does |
|---------------------|-----------------|
| `parentEntry` / `parent_entry` | Unknown key → `EFRONTMATTER` |
| Nested mappings / block scalars | `EFRONTMATTER` |
| Arbitrary extra keys | `EFRONTMATTER` |
| UTF-8 BOM | `EINVALIDUTF8` |

## Examples

```markdown
---
title: My guide
parent: guides
status: published
tags: [guides, setup]
---
```

Path-derived id for this file is `guides/authoring-frontmatter` (no `id:`
override). Explicit overrides must still pass identity validation — see
[[reference/entity-ids]].

## Full reference

[[reference/frontmatter|Frontmatter reference]] and
[[concepts/parent-keys|parent key rules]].
