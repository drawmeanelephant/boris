---
title: Slots and rules
parent: reference
status: published
tags: [reference, layouts, assets]
---

# Slots and rules

This page is a compact checklist for authors building a theme like this one.

## Layout slots used here

| Marker | Role in this theme |
|--------|--------------------|
| `{{content}}` | Required article body |
| `{{title}}` | Document title text |
| `{{nav}}` | Full Trunk/Satellite forest |
| `{{breadcrumb}}` | Root → current trail |
| `{{toc}}` | Page-local h1–h3 outline |
| `{{children}}` | Direct frozen children only |
| `{{metadata}}` | Status / tags fragment |
| `{{footer}}` | Theme `footer.html` |
| `{{asset-url …}}` | Page-relative theme asset URL |

Every known marker may appear **at most once**. Unknown markers fail layout
load.

## Layout-rule variation

This example selects layouts without any frontmatter layout key:

```bash
--layout-rule default id:index \
  examples/reference-theme/theme/layouts/home.html
--layout-rule default role:trunk \
  examples/reference-theme/theme/layouts/section.html
```

| Selector | Layout | Visible difference |
|----------|--------|--------------------|
| `id:index` | `home.html` | Hero + children featured; no TOC rail |
| `role:trunk` | `section.html` | Children-first column; compact chrome |
| fallback | `main.html` | Three-column docs shell with TOC |

Rules are evaluated in declaration order; first match wins. The fallback
layout is the theme’s `layouts/main.html` (via `--theme`).

## Asset ownership

| Kind | Source | Published path |
|------|--------|----------------|
| Theme asset | `theme/assets/**` | `{target}/assets/**` |
| Page-local asset | `{stem}.assets/**` next to the page | `{entity_id}.assets/**` |

Theme assets are referenced with `{{asset-url assets/…}}`. Page-local images
use Markdown image syntax pointing into the sibling tree (see the home page
figure under its sibling `index.assets/` directory).

## Boundaries (do not cross)

- No Node, npm, Tailwind build, CDN, or JavaScript runtime
- No new frontmatter keys or template language
- No compiler changes from an example theme PR
- No network fetch during build or page load for theme resources

## Further reading

Normative contracts in the repository:

- `docs/contracts/templating-and-themes.md`
- `docs/contracts/html-output.md`
- `docs/contracts/content-local-assets.md`
- `docs/contracts/components.md`
