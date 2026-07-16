---
title: Why multi-layout still shares one theme
parent: blog
status: published
tags: [blog, layouts]
---

# Why multi-layout still shares one theme

`--layout-rule` can point each page at a different HTML template, but every
rule for a target must share **one managed theme root**. That keeps:

- one `assets/` inventory
- one `footer.html`
- one CSS/brand story

## Practical shape

| Page kind | Layout | Shared theme pieces |
|-----------|--------|---------------------|
| Home | `home.html` | CSS, mark, footer |
| Section trunks | `section.html` | same |
| Blog posts | `blog.html` | same |
| Guide/reference leaves | `main.html` | same |

Different targets may use different themes; one target may not mix
`theme-a/layouts/…` with `theme-b/layouts/…`.

## Determinism

Rule order on the command line does not matter. Canonical selection and
cache keys treat rules as an ordered set by selector rank and bytes, so
repeated full and incremental builds stay byte-stable for identical inputs.

<Aside kind="tip">

Grep for `data-layout=` in the HTML output to confirm selection without
reading full documents.

</Aside>
