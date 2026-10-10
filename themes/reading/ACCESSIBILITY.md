# Accessibility notes

What Reading guarantees, checked against the built output and
`assets/reading.css`.

- The first focusable element is a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`). Header, a labelled site `nav`, `main`, a
  labelled TOC `aside`, and the footer are landmarks.
- All colors derive from system `Canvas`/`CanvasText`, so light, dark, and
  forced-colors modes keep the browser's own contrast.
- `:focus-visible` draws a 3px outline at 55% `CanvasText` with a 3px offset:
  about 4.7:1 on a white canvas and about 6.2:1 on a `#121212` canvas, above
  the 3:1 non-text floor.
- `:lang(ja)`, `:lang(zh)`, and `:lang(ko)` raise line-height, use strict
  line breaking, and replace italic emphasis with weight, so emphasis stays
  visible in scripts without true italics.
- The theme adds no visible English labels of its own; relations and
  backlinks reuse the compiler's `aria-label` as their heading.
- Tables and code blocks scroll horizontally instead of shrinking.
- `prefers-reduced-motion: reduce` disables animations and transitions.
- `@media print` drops the skip link and rails, widens the measure, and wraps
  code blocks.
- The TOC and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`; compiler metadata stays out of the
  rendered-search index.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
