---
title: Slots and responsive behavior
parent: reference
status: published
tags: [reference, accessibility]
---

# Slots and responsive behavior

The layout uses the existing Boris insertion points as named, inspectable
places for generated content.

## Slot map

| Slot | Location | Purpose |
|---|---|---|
| `{{nav}}` | rail | graph navigation |
| `{{breadcrumb}}` | header | current path |
| `{{toc}}` | rail | page-local headings |
| `{{metadata}}` | article top | status and tags |
| `{{children}}` | section panel | direct graph children |
| `{{content}}` | article body | rendered Markdown and Aside |
| `{{footer}}` | footer | static theme note |

## Responsive behavior

The three-column reading shell becomes two columns at 58rem and one column at
42rem. Navigation and the page outline remain present as ordinary blocks. The
table above can scroll horizontally, and `:focus-visible` keeps keyboard focus
clear against both light and dark surfaces.

<Aside kind="tip">

The theme has no menu button to get stuck behind a runtime state. Native links,
headings, and the skip link are enough for this static prototype.

</Aside>
