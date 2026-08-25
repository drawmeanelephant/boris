---
title: Frontmatter used here
parent: reference
status: published
tags: [reference, frontmatter]
---

# Frontmatter used here

Showcase pages stick to Boris’s closed five-key grammar:

| Key | Purpose in this site |
|-----|----------------------|
| `title` | Document title + layout `{{title}}` |
| `parent` | Satellite → trunk edge (`guides/…` → `guides`) |
| `status` | Appears in `{{metadata}}` |
| `tags` | Appears in `{{metadata}}` |
| `id` | *(unused here)* explicit entity id override |

There is **no** `layout:` key. Unknown keys (including `layout`) are
`EFRONTMATTER` failures. Layout selection is build configuration only.

## Example satellite

```yaml
---
title: Getting started
parent: guides
status: published
tags: [guides, onboarding]
---
```

## Graph shape

Trunks: `index`, `guides`, `reference`, `blog`  
Satellites: children under `guides/`, `reference/`, and `blog/`.
