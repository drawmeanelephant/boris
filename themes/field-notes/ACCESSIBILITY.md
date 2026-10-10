# Accessibility notes

What Field Notes guarantees, checked against the built output and
`assets/field-notes.css`.

- Every layout starts with a skip link to `#main-content`, the `main` element
  (`tabindex="-1"`). Header, navigation `aside`s, `main`, and footer carry
  landmark roles or labels.
- `:focus-visible` draws a 3px amber outline with a 3px offset. Measured
  against the page: 5.26:1 in light mode (`#a05b00` on `#fff`) and 8.93:1 in
  dark mode (`#f1bd73` on `#20262b`), above the 3:1 non-text floor.
- Links keep underlines in body copy. The draft stamp pairs its amber color
  with the uppercase word "draft"; color is never the only signal.
- Below 42rem the browse rail becomes a native `<details>` disclosure, so the
  navigation stays keyboard-operable without JavaScript. Nothing is hidden on
  small screens.
- `prefers-color-scheme: dark` swaps the whole palette.
  `prefers-reduced-motion: reduce` collapses scroll behavior, transitions,
  and animations.
- `@media print` drops the skip link and rails, flattens the grids, and wraps
  code blocks. Content, metadata, and relations still print.
- The TOC rail and the status/parent/tags header are
  `data-boris-search-exclude`, so none of them enter the rendered-search
  index (verified: a unique tag and the status word are absent from
  `search-index.json`).

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
