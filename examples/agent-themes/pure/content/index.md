---
title: Pure Field Notes
status: published
tags: [home, theme, pure]
---

# A small, steady documentation surface

Pure Field Notes is an independent theme prototype for Boris. It keeps the
reading line quiet: a slim blue rule, compact navigation, ordinary HTML, and a
stylesheet small enough to understand in one sitting.

## Start with the working example

This tree exercises a complete Boris theme rather than a static mockup:

| Surface | Demonstrated by |
| --- | --- |
| Theme-owned CSS | `{{asset-url assets/pure-field-notes.css}}` |
| Graph navigation | The Browse rail and breadcrumb |
| Responsive layout | Three columns on wide screens; one column on narrow screens |
| Page metadata and TOC | The Satellite reading layout |
| Native components | `Aside` callouts and `Details` disclosures |

{{children}}

<Aside kind="tip" id="keep-it-small">

Start with semantic HTML and a few local rules. A theme should make the
content easier to scan, not become a second application to maintain.

</Aside>

<Details summary="Why call this Pure-inspired instead of Pure.css?" id="inspiration-boundary" open="true">

The official Pure project emphasizes small modules, responsive behavior, and a
minimal flat foundation. This example applies those ideas with its own tokens,
markup, and content. It does not copy the Pure stylesheet or load it from a
CDN.

</Details>

## The next two stops

- [Guides](guides.md) — build and inspect the example.
- [Reference](reference.md) — see how the closed Boris slots map to the layout.
