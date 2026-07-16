---
title: From Docusaurus
parent: cookbook
status: published
tags: [cookbook, docusaurus]
---

# From Docusaurus

## Typical mapping

| Docusaurus | Boris |
|------------|-------|
| `docs/**/*.md(x)` | `.md` / `.mdx` pages (no React MDX components) |
| `_category_.json` | Trunk landing page + titles |
| `sidebar_position` | Optional only — order follows graph/determinism, not weights |
| `@site` links | Wiki entity ids |
| MDX components | Replace with Markdown / Aside / includes |
| `static/` | Theme `assets/` |

```markdown
[[guides/getting-started|Getting started]]
[[reference/cli]]
```

## MDX caution

Boris is not a React runtime. Executable MDX and arbitrary imports must be
removed or rewritten to static Markdown before the content graph will compile.
