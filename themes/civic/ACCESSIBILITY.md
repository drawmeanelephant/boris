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
- Contrast. Links `#005ea8` are 6.63:1 on white and 5.87:1 on the
  `#f1f1f1` page. Dark mode now overrides links to `#73b3e7` (7.65:1 on
  `#1b1b1b`, 6.29:1 on the `#2b2b2b` surface); before #1049 dark links kept
  `#005ea8` and measured 2.60:1. Muted text `#5c5c5c` is 5.92:1 on the page.
- Alerts (callouts) are tinted panels with ink text: 13.8–15.5:1 on the
  light tints and 11.5–13.4:1 on the dark tints; links inside them stay at
  5.32:1 or better (light) and 5.58:1 or better (dark). Each keeps its text
  title; the edge colour is secondary: note `#005ea8`, info `#0081a1`
  (4.51:1 on white), tip `#008817` (4.63:1), warning `#c05600` (4.59:1),
  danger `#b50909` (6.98:1). Before #1049 warning and danger shared one
  red.
- The current page in the header nav (compiler `aria-current="page"`) gets
  a gold bar under it, a shape cue rather than a text colour change.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, banner, header, footer, and sidebar; flattens the grid;
  forces black on white (resetting the palette, so a dark-mode reader does not
  print dark alert tints); and wraps code blocks.
- Relations and backlinks keep their compiler `aria-label`s and gain visible
  headings from the theme. The header nav and breadcrumb wrappers are plain
  `div`s; their former `aria-label`s sat on role-less elements and were
  never announced. The compiler's `nav aria-label="Site"` and
  `nav aria-label="Breadcrumb"` inside them are the landmarks.
- The TOC rail, the children panel, layout kickers, the layout title `h1`,
  and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`; compiler metadata stays out of the
  rendered-search index. The layout `h1` also carries
  `data-boris-search-title="layout"`, so a page with no authored heading is
  still titled by its page title in `_boris/search/search-index.json`
  (verified; before this pass it indexed as "Civic").

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
