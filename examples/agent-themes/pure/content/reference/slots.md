---
title: Slots and accessibility
parent: reference
status: published
tags: [reference, layouts, accessibility]
---

# Slots and accessibility

The layouts use the closed Boris markers exactly once each. There are no
conditionals, loops, custom template expressions, or page-authored layout
keys.

## Marker map

| Marker | Placement in this prototype |
| --- | --- |
| `{{content}}` | Required article body |
| `{{title}}` | Document title and visible page heading context |
| `{{nav}}` | Browse rail or compact mobile menu |
| `{{breadcrumb}}` | Header trail above the article |
| `{{toc}}` | On this page rail |
| `{{children}}` | Home and section landing cards |
| `{{metadata}}` | Status and tag definition list |
| `{{footer}}` | Local static footer fragment |
| `{{asset-url assets/pure-field-notes.css}}` | Page-relative stylesheet link |

## Responsive behavior

At wide widths, the main layout is a grid with a navigation rail, a bounded
reading column, and a TOC rail. At the breakpoint, the rails become ordinary
flow content: the TOC moves below the article and the Browse navigation is
inside a native disclosure. The page remains usable with zoom and without
hover.

## Accessibility checklist

- Skip link targets the unique `main` element.
- Landmarks have names where more than one navigation region exists.
- Current graph links use Boris's emitted `aria-current` state.
- Focus rings are visible against both light and dark system color schemes.
- Warnings use a left rule and text label, not color alone.
- `Details` keeps the native `summary` control and keyboard semantics.
- Motion is reduced when the user requests `prefers-reduced-motion`.

<Details summary="Why not add a JavaScript menu?" id="no-runtime">

The mobile menu is a native `<details>` element. It provides disclosure,
keyboard operation, and a useful no-script fallback without adding a runtime
dependency to a static documentation site.

</Details>
