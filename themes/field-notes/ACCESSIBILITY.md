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
- Visited links shift to indigo (`#55489a`, 7.55:1 on white, 7.03:1 on the
  wash; `#c3b8f0`, 8.33:1 on the dark paper); hover thickens the underline.
  The current page in the browse rail has a 3px blue edge and bold weight
  as well as `aria-current="page"`.
- Aside kinds keep their uppercase word. The tip kind is green (`#2d6a3e`,
  5.88:1 on its wash; `#9fd8ad`, 8.27:1 on the dark wash) and the note kind
  is neutral ink on the grey wash, so the five kinds are not all blue.
- The "In this section" children panel hides when the trunk has no
  children, so its label is never read over an empty region.
- Below 42rem the browse rail becomes a native `<details>` disclosure, so the
  navigation stays keyboard-operable without JavaScript. Nothing is hidden on
  small screens.
- `prefers-color-scheme: dark` swaps the whole palette.
  `prefers-reduced-motion: reduce` collapses scroll behavior, transitions,
  and animations.
- `@media print` drops the skip link and rails, flattens the grids, and wraps
  code blocks. Content, metadata, and relations still print.
- The TOC rail, the status/parent/tags header, the `graph-links`
  relations/backlinks wrapper, the home kicker and map, and the section
  children panel are `data-boris-search-exclude`, so none of them enter the
  rendered-search index (verified: a unique tag, the status word, and
  relation link titles are absent from `search-index.json`).

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
