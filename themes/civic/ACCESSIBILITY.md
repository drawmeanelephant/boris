# Accessibility notes

What Civic guarantees, checked against the built output and
`assets/css/civic.css`.

- Every layout starts with a "Skip to main content" link to `#main-content`, the `main`
  element (`tabindex="-1"`, so focus lands on it in every browser).
- `:focus-visible` is two-tone: the theme's 0.25rem gold (`#ffbe2e`) outline sits outside a
  0.15rem ring in the text color. The ink ring carries the contrast:
  15.3:1 in light mode (`#1b1b1b` on `#f1f1f1`) and
  15.8:1 in dark mode (`#f5f5f5` on `#1b1b1b`). The
  accent alone measures 1.5–1.7:1 on the light background, which is
  why the ring is there; it measures 10.4:1 in dark mode.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, banner, header, footer, and sidebar; flattens the grid;
  forces black on white; and wraps code blocks.
- Relations and backlinks keep their compiler `aria-label`s and gain visible
  headings from the theme.
- The TOC rail, the children panel, layout kickers, the layout title `h1`,
  and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`; compiler metadata stays out of the
  rendered-search index. The layout `h1` repeats the page's own heading, so
  a page with no authored `h1` has no indexed `h1` and its search title falls
  back per the rendered-search contract (currently the page path).

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
