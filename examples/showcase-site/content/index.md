---
title: Boris Static Theme Showcase
status: published
tags: [home, theme, showcase]
---

# Welcome

This optional example is a small **docs + blog** site that exercises Boris’s
existing theme path:

| Feature | Where it shows up |
|---------|-------------------|
| Theme root + assets | `theme/assets/` copied via `{{asset-url …}}` |
| Footer fragment | `theme/footer.html` → `{{footer}}` |
| Site nav / breadcrumb / TOC | closed layout slots |
| Page metadata | `status` + `tags` → `{{metadata}}` |
| Multi-layout selection | `--layout-rule` (home / section / blog / main) |

## Start here

- [Getting started with the showcase](guides/getting-started.md)
- [How layout rules pick templates](guides/theme-layouts.md)
- [CLI notes for themes](reference/cli-theme.md)
- [Blog: building without a CSS toolchain](blog/first-post.md)

<Aside kind="tip">

This directory is not product chrome. Boris does not ship DaisyUI or any
component framework. The stylesheet is hand-authored and local-only.

</Aside>

## What this proves

1. A polished site can be assembled from Markdown + a theme root.
2. Multiple page shapes share one theme’s assets and footer.
3. Builds stay offline: no CDN links, no Node, no Tailwind CLI.
