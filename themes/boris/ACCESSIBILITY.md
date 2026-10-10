# Accessibility notes

What the default theme guarantees, checked against the built output and
`assets/css/boris.css`.

- The first focusable element is a skip link to `#main-content`, which is the
  `main` element (`tabindex="-1"`, so focus lands on it in every browser).
- The page has a named `main`, a `footer`, a labelled search region, and the
  graph navigation inside a native `<details>` disclosure that is open by
  default and keyboard-operable without JavaScript.
- Every focusable element gets a 3px `:focus-visible` outline in the theme's
  accent ink, offset 3px. Measured against the page canvas it is 5.68:1 in
  light mode (`#ae4622` on `#fff`) and 5.6–6.3:1 in dark mode (`#e17955` on
  `#1e1e1e`–`#121212`), above the 3:1 non-text contrast floor.
- Colors come from system `Canvas`/`CanvasText`, so `prefers-color-scheme`
  and forced-colors modes keep the browser's own contrast.
- Relations and backlinks keep their compiler `aria-label`s ("Semantic
  relations", "Backlinks"). The theme adds a visible heading and the relation
  kind as CSS text; the link text itself is the target page title.
- `prefers-reduced-motion: reduce` disables all animations and transitions.
- `@media print` drops the skip link, search, and menu, flattens the grid,
  removes card chrome, and wraps code blocks.
- Search is a progressive enhancement: without JavaScript a `<noscript>`
  message points back to the navigation. The TOC, compiler metadata, and the
  `graph-links` relations/backlinks wrapper stay out of the rendered-search
  index (`data-boris-search-exclude`, compiler chrome rules), so a page's
  entry holds only its authored text.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
