---
title: From Hugo
parent: cookbook
status: published
tags: [cookbook, hugo]
---

# From Hugo

## Typical mapping

| Hugo | Boris |
|------|-------|
| `content/**/*.md` | `content/**/*.md` (same idea) |
| `title` in front matter | `title` |
| Menu / section weight | One-level `parent` Trunk ids + site nav |
| `layouts/` templates | Theme `layouts/*.html` with closed markers |
| `static/` | Theme `assets/` + asset-url helper |
| Shortcodes | Prefer Markdown + Aside; no arbitrary execution |
| `ref` / `relref` | Wiki links by entity id (page or heading) |

Wiki / include examples stay fenced so they are not resolved as live syntax:

```markdown
[[guides/getting-started|Getting started]]
[[guides/heading-fragments#hello-world]]
{{include includes/shared-callout.md}}
```

## Steps

1. Copy Markdown bodies; strip unsupported frontmatter keys.
2. Introduce Trunk landing pages per major section.
3. Set `parent:` on section children to those Trunk ids.
4. Replace shortcodes with includes or Asides.
5. Port CSS into `theme/assets/` and wire the theme layout.
6. Compile with [[reference/cli|fixture CLI]] until exit 0.
