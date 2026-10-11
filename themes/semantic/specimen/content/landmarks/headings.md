---
title: Heading hierarchy
parent: landmarks
status: published
tags: [headings, structure]
---

# Heading hierarchy

Headings are the page's outline whether or not anyone draws it. A screen
reader can jump heading to heading; a search engine reads the same tree. One
`h1`, then `h2`, then `h3`, with no level skipped for looks.

## One name at the top

The page title is the `h1`. The layout sets it once from the page's own title,
so the visible heading and the browser-tab title cannot disagree about what
this page is called.

## Nest, never skip

An `h3` under an `h2` is a part of a section. An `h3` with no `h2` above it is
a part of nothing.

| Level | Meaning on this page |
|-------|----------------------|
| `h1` | The page |
| `h2` | A section of the page |
| `h3` | A part of that section |
| `h4` and deeper | Within a part, never a heading for a whole region |

> Outline first, styling second. The level you need is a structural choice,
> not a type scale.

<Aside kind="tip">

Every heading here carries an `id`, which is why the outline beside this
column can link straight to it. Change the words and the anchor follows.

</Aside>

Back to [One main region](main.md).
