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
  5.36–5.74:1 on the panels (4.94:1 on the danger Aside tint).
- Visited links turn plum (`#6e3d6e`, 8.22:1 on the panel, 7.67:1 on the
  module tint); hover switches the underline to dotted, so the state is not
  colour-only. The current page in the sidebar navigation is bold ink with a
  `»` marker (decorative, empty alt text) and carries `aria-current="page"`.
- Aside titles stay words. Their colours measure 5.18:1 (tip, rust on
  `#fdf3ea`), 6.11–6.38:1 (info and note, `#3f5f6e`), 5.89:1 (warning,
  `#7a5a00` on `#fdf6dc`), and 7.98:1 (danger, `#8a1c1c` on `#fbeaea`);
  danger also has a dashed border.
- The site name in the banner is a paragraph, not a heading, so the
  entry's own `h1` is the page's only top-level heading. The breadcrumb is an
  inline trail with `»` separators that are hidden from assistive tech.
- The "Recent posts" panel is hidden when the page has no children, so its
  heading is never announced over an empty region.
- The draft and archived stamps are text, not color alone.
- The two-column layout collapses to one column below 760px without hiding
  navigation or content.
- Reduced-motion preferences disable transitions and smooth scrolling.
- `@media print` drops the skip link and sidebar, removes the header
  gradient and page shadow, and wraps code blocks.
- The local illustration has a title and description in its SVG metadata.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
