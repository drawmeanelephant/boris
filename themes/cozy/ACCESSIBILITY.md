# Accessibility notes

- The first focusable element is a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`).
- The layout uses explicit header, main, article, nav, aside, section, and
  footer landmarks.
- The avatar is a labeled initial, not a remote image or decorative asset.
- Links keep visible underlines. `:focus-visible` adds a 2px dashed slate
  outline with a 3px offset and a pale tint; the outline measures 3.65:1 on
  the paper background and 4.08:1 on the focus tint (`#5a7b8c`), above the
  3:1 non-text floor.
- Secondary text (`--quiet`, `#666`) measures 4.64:1 on the paper and
  5.36–5.74:1 on the panels.
- The draft and archived stamps are text, not color alone.
- The two-column layout collapses to one column below 760px without hiding
  navigation or content.
- Reduced-motion preferences disable transitions and smooth scrolling.
- `@media print` drops the skip link and sidebar, removes the header
  gradient and page shadow, and wraps code blocks.
- The local illustration has a title and description in its SVG metadata.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
