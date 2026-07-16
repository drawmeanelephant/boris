---
title: Theme layouts and layout rules
parent: guides
status: published
tags: [guides, layouts]
---

# Theme layouts and layout rules

Layouts are trusted static HTML with closed Boris markers. Page authors do
**not** pick a layout in frontmatter; the build does via `--layout-rule`.

## Theme shape

```text
theme/
  layouts/
    main.html      # fallback (satellite docs pages)
    home.html      # id:index
    section.html   # role:trunk
    blog.html      # glob:blog/*
  footer.html
  assets/css/showcase.css
  assets/img/mark.svg
```

## Selectors used here

| Selector | Layout | Example pages |
|----------|--------|----------------|
| `id:index` | `home.html` | site home |
| `glob:blog/*` | `blog.html` | blog posts |
| `role:trunk` | `section.html` | `guides`, `reference`, `blog` trunks |
| *(fallback)* | `main.html` | satellites under guides/reference |

Precedence is fixed: exact id → glob specificity → role → target/theme
fallback → product default. Rule declaration order never changes the winner.

## Closed slots in use

- `{{content}}` — required body
- `{{title}}`, `{{nav}}`, `{{breadcrumb}}`, `{{toc}}`, `{{metadata}}`, `{{footer}}`
- `{{asset-url assets/…}}` — page-relative URL + copy into the target

## Verify the winner

Each layout stamps `data-layout` on `<html>` and `<body>`:

```bash
rg -n 'data-layout=' test-output/static-theme-showcase/*.html \
  test-output/static-theme-showcase/*/*.html
```

Expect `home` on `index.html`, `section` on trunk pages, `blog` under
`blog/`, and `main` on ordinary satellites.
