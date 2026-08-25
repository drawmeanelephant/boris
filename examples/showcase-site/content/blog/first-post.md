---
title: Building a theme without a CSS toolchain
parent: blog
status: published
tags: [blog, theme, offline]
---

# Building a theme without a CSS toolchain

Modern component libraries often assume Node, a Tailwind pipeline, or a
browser CDN. Boris’s theme contract is the opposite: **trusted static HTML**,
**local assets**, and **no network during compile**.

## What we wanted

A docs/blog look with:

- soft surfaces and clear hierarchy
- badges and cards for chrome
- readable prose, tables, and asides
- dark-mode tokens via `prefers-color-scheme`

## What we did not ship

<Aside kind="warning">

Official DaisyUI CSS is a Tailwind-oriented component layer. The CDN path
pulls Tailwind’s browser runtime; the standalone CLI path is still a CSS
build step. Neither fits “no Node / no runtime compiler / no network” for
this optional example without claiming more than Boris provides.

</Aside>

So the showcase uses a **hand-authored** stylesheet inspired by that clean
component feel, documented as such in the example README.

## Offline by construction

Layout links look like:

```html
<link rel="stylesheet" href="{{asset-url assets/css/showcase.css}}">
```

Boris resolves the path under the theme, copies bytes into the target, and
emits a page-relative URL. There is nothing to fetch at build time or at
first paint when viewing local files.
