---
title: Theme reference
status: published
tags: [reference, slots]
---

# Theme reference

This page documents the small contract surface the prototype consumes. The
source stays ordinary Boris HTML and Markdown: the only special pieces are the
closed layout slots already supported by the compiler.

## Two page shapes

The home page is selected with an exact `id:index` rule. All other pages use
`theme/layouts/main.html`, which keeps the same stylesheet and accessibility
features while adding navigation and an in-page outline.

The child page below shows how a Satellite stays in the same graph without
needing a page-authored layout key.
