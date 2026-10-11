---
title: The structure is the surface
status: published
tags: [home, landmarks, headings]
---

# Structure you can point at

A semantic page tells the truth about itself. Long after this stylesheet is
gone, the elements underneath still say what each part is: a banner, a set of
links, the one primary region, a self-contained article, a colophon.

That is the whole idea of this theme. Colour is a coat; the markup is the
body. This specimen is a working document, and the landmarks it names are the
landmarks of the page you are reading right now.

## The six landmarks in this document

| Landmark | What it says |
|----------|--------------|
| `header` | The banner: site identity and the start of the page |
| `nav` | A set of related links, named with `aria-label` |
| `main` | The one primary region — exactly once per document |
| `article` | A composition that would survive being clipped out |
| `aside` | Support that is related but optional to follow along |
| `footer` | Provenance and the quiet end of the page |

Below them sit elements that are already interactive: `a`, `button`,
`details`, `summary`. The theme styles them; it does not replace them.

## Headings are an outline

One `h1` names the page. `h2` opens a section, `h3` opens a subsection, and no
level is skipped. Because the order is real, the outline beside this column is
generated from it rather than kept by hand.

```html
<main id="main-content">
  <article>
    <h1>One page, one name</h1>
    <h2>A section</h2>
    <h3>A part of that section</h3>
  </article>
</main>
```

## Native components do the work

Disclosure is `details`. Tabulation is `table`. Definitions are `dl`. None of
them needs a script, a `role`, or a `tabindex`; each is operable by keyboard
and announced by name before any CSS loads.

<Aside kind="note">

The accent colour in this theme marks links and focus. It never carries
meaning on its own — status, hierarchy, and kind are always written out.

</Aside>

<Details summary="Why not style a div instead?">

A `div` with the right classes can look like anything. It can also be
announced as nothing. Choose the element whose meaning you actually want,
then style that.

</Details>

## Follow the structure

- [Landmarks](landmarks.md) — the six regions, demonstrated in place
- [Patterns](patterns.md) — headings, disclosure, tables, and definitions

Read the entries in either order. Both end at the same place: markup a person
could read aloud.
