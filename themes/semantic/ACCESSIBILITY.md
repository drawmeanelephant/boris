# Accessibility notes

What Semantic guarantees, checked against the built output and
`assets/css/semantic.css`.

- Every layout starts with a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`, so focus lands on it in every browser).
- `:focus-visible` is two-tone: the theme's 0.2rem amber (`#f59f00`) outline sits outside a
  0.2rem ring in the text color. The ink ring carries the contrast:
  15.5:1 in light mode (`#17211b` on `#f7f8f6`) and
  16.2:1 in dark mode (`#edf6ee` on `#111914`). The
  accent alone measures 2.0–2.1:1 on the light background, which is
  why the ring is there; it measures 8.4:1 in dark mode.
- Contrast. Links `#087f5b` are 5.00:1 on white and 4.70:1 on the page
  background. Dark mode now overrides the accent to `#3fd39a` (9.37:1 on
  `#111914`, 8.47:1 on the `#19231c` surface); before #1049 dark links kept
  the light accent and measured 3.58:1. Muted text `#65736a` is 4.68:1 on the
  background. Callout edges are a secondary cue next to the text title: note
  and info `#1864ab` (6.09:1 on white), warning `#d9480f`, danger `#c92a2a`
  (5.46:1); dark `#74c0fc` (8.23:1) and `#ff8787` (6.98:1) on the surface.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, header, footer, and rails; flattens the grid;
  forces black on white; and wraps code blocks.
- Relations and backlinks keep their compiler `aria-label`s and gain visible
  headings from the theme. The header and breadcrumb wrappers are plain
  `div`s with no `aria-label` (a label on a role-less `div` is never
  announced); the compiler's own `nav aria-label="Site"` and
  `nav aria-label="Breadcrumb"` inside them are the landmarks. The current
  page in the site nav carries `aria-current="page"` from the compiler and is
  drawn in ink with an accent underline bar, not by colour alone.
- The TOC rail, the children panel, layout kickers, the layout title `h1`,
  and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`; compiler metadata stays out of the
  rendered-search index. The layout `h1` also carries
  `data-boris-search-title="layout"`, so a page with no authored heading is
  still titled by its page title in `_boris/search/search-index.json`
  (verified: a headingless satellite indexes as its frontmatter `title`; before
  this pass it indexed as "Semantic").

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
