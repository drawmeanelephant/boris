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
- The color-mode toggle is a native `<button>` with an `aria-label`; the
  initial mode follows `prefers-color-scheme` and is applied before paint.
  Without JavaScript the page stays in the dark default and remains usable.
- Search is a progressive enhancement over the first-party index. Results
  are an ordered list with a polite live status; without JavaScript a
  `<noscript>` note points to the navigation tree. Breadcrumb, rail, and TOC
  are `data-boris-search-exclude`.
- Relations and backlinks keep their compiler `aria-label`s inside the
  graph panel, with the relation kind shown as text. Empty panel blocks are
  hidden.
- No motion is emitted; `prefers-reduced-motion: reduce` still pins scroll
  behavior, transitions, and animations off.
- `@media print` renders dark ink on white in every mode and drops the
  header, rail, search, breadcrumb, and graph panel. `layouts/print.html` is
  the same shape as a selectable layout.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
