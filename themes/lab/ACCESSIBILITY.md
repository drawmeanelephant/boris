# Accessibility notes

What lab guarantees, checked against the built output and
`assets/css/lab.css` + `assets/css/modes.css`.

- `layouts/main.html` starts with a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`). `layouts/print.html` is a single article with
  no chrome to skip.
- `:focus-visible` draws a 2px accent outline with a 2px offset in all three
  modes. Measured against the page background and panels: dark 12.3–13.0:1
  (`#5eead4`), light 4.9–5.5:1 (`#0f766e`), pride 8.6–9.2:1 (`#ff8ae2`),
  all above the 3:1 non-text floor. The search input keeps that outline
  instead of suppressing it.
- Body text measures 11.9–14.8:1 across the modes. Secondary text
  (`--muted`) measures 5.0–5.3:1 in dark, 4.9–5.2:1 in light, and 6.6:1 in
  pride.
- Aside titles take a per-mode kind colour (`--k-*`), measured on the Aside
  panel: dark note 10.91:1, tip 12.30:1, info 9.12:1, warning 10.90:1,
  danger 6.58:1; light note 5.93:1, tip 5.47:1, info 6.29:1, warning
  5.02:1, danger 6.47:1; pride note 11.41:1, tip 14.78:1, info 8.14:1,
  warning 12.55:1, danger 7.97:1. Every kind also keeps its word.
- The color-mode toggle is a native `<button>` with an `aria-label`; the
  initial mode follows `prefers-color-scheme` and is applied before paint.
  Without JavaScript the page stays in the dark default and remains usable.
- Search is a progressive enhancement over the first-party index. Results
  are an ordered list with a polite live status; without JavaScript a
  `<noscript>` note points to the navigation tree. Breadcrumb, rail, TOC,
  and the graph panel are `data-boris-search-exclude`.
- Relations and backlinks keep their compiler `aria-label`s inside the
  graph panel, with the relation kind shown as text. Empty panel blocks are
  hidden, and so is the whole panel when it has no links.
- No motion is emitted; `prefers-reduced-motion: reduce` still pins scroll
  behavior, transitions, and animations off.
- `@media print` swaps every mode's palette for a paper palette (ink
  `#111`, headings `#000`, muted `#444`, links `#0f5f58` at 7.51:1, kind
  titles 7.09:1 or better on white) and drops the header, rail, search,
  breadcrumb, and graph panel. Before this, dark and pride printed headings
  and bold text in their screen colours, near-white on paper.
  `layouts/print.html` is the same shape as a selectable layout and renders
  in the light palette on screen too (`data-theme="light"`).


This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
