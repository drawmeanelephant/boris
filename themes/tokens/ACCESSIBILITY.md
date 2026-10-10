# Accessibility notes

What Tokens guarantees, checked against the built output and
`assets/css/tokens.css`.

- Every layout starts with a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`, so focus lands on it in every browser).
- `:focus-visible` is two-tone: the theme's 0.2rem amber (`#fab005`) outline sits outside a
  0.2rem ring in the text color. The ink ring carries the contrast:
  14.5:1 in light mode (`#20212d` on `#f5f4f0`) and
  15.9:1 in dark mode (`#f6f3ea` on `#19181d`). The
  accent alone measures 1.7–1.8:1 on the light background, which is
  why the ring is there; it measures 9.5:1 in dark mode.
- Contrast. Links `#6f42c1` are 6.45:1 on the `#fffef9` card and 5.92:1 on
  the page; hover `#c2410c` is 5.13:1 (the previous hover `#e8590c` was
  3.55:1). Dark mode now overrides links to `#b197fc` (6.43:1 on `#25232b`,
  7.31:1 on `#19181d`) with hover `#ffa94d` (8.15:1); before #1049 dark links
  kept `#6f42c1` and measured 2.38:1. Muted text `#6d6d7a` is 4.63:1 on the
  page and 5.05:1 on cards.
- Callouts keep their text title, drawn in the kind token: note/info
  `#1d5fa8` (6.39:1 on the card), tip `#1f7a52` (5.25:1), warning `#a34e00`
  (5.70:1), danger `#b42318` (6.51:1); dark `#74c0fc` (7.89:1), `#63e6be`
  (10.04:1), `#ffc078` (9.65:1), `#ff8787` (6.70:1) on `#25232b`. Before
  #1049 tip and info shared the accent, warning and danger shared orange,
  and note had no edge.
- The current page in the header nav (compiler `aria-current="page"`) is an
  ink pill with card-coloured text, a shape change and not colour alone.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, header, footer, and rails; flattens the grid;
  forces black on white; and wraps code blocks.
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
  (verified; before this pass it indexed as "Tokens").

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
