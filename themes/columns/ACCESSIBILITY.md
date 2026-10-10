# Accessibility notes

What Columns guarantees, checked against the built output and
`assets/css/columns.css`.

- Every layout starts with a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`, so focus lands on it in every browser).
- `:focus-visible` is two-tone: the theme's 0.2rem yellow (`#ffdd57`) outline sits outside a
  0.2rem ring in the text color. The ink ring carries the contrast:
  14.9:1 in light mode (`#18212b` on `#f3f5f7`) and
  16.2:1 in dark mode (`#f0f4f7` on `#12181e`). The
  accent alone measures 1.2–1.3:1 on the light background, which is
  why the ring is there; it measures 13.4:1 in dark mode.
- Contrast. Links `#006f5a` are 6.14:1 on white; dark links `#5fe2bd`.
  Muted text was darkened in #1049 from `#6b7785` (4.17:1 on the `#f3f5f7`
  page, where the breadcrumb and relation eyebrow sit) to `#5c6774` (5.27:1
  on the page, 5.76:1 on white); dark muted `#a8b3be` is 8.39:1. Callout
  edges are a secondary cue next to the text title: note/info `#2160c4`
  (5.94:1 on white), warning `#9a6200` (5.10:1), danger `#cc0f35` (5.70:1);
  dark `#7fb8ff` (7.64:1), `#ffc966` (10.33:1), `#ff8fa3` (7.27:1) on
  `#1b242c`.
- The current page in the navbar (compiler `aria-current="page"`) is drawn
  as an ink pill with surface text, a shape change and not colour alone.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, navbar, footer, and sidebar; flattens the grid;
  forces black on white; and wraps code blocks.
- Relations and backlinks keep their compiler `aria-label`s and gain visible
  headings from the theme. The navbar and breadcrumb wrappers are plain
  `div`s: the navbar `div` used to carry an `aria-label` with no role (never
  announced) and the breadcrumb wrapper was a second labelled `nav` around
  the compiler's own `nav aria-label="Breadcrumb"`. The compiler's labelled
  `nav` elements are now the only landmarks.
- The TOC rail, the children panel, layout kickers, the layout title `h1`,
  and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`; compiler metadata stays out of the
  rendered-search index. The layout `h1` also carries
  `data-boris-search-title="layout"`, so a page with no authored heading is
  still titled by its page title in `_boris/search/search-index.json`
  (verified; before this pass it indexed as "Columns").

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
