# Accessibility notes

- The first focusable element is a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`).
- The page uses header, nav, main, article, section, aside, and footer
  landmarks. The node tracker is a labelled `nav`; the sidebar is a labelled
  `aside`.
- There is no search box, login, or other control that would need a runtime.
  Navigation is the graph.
- `:focus-visible` draws a 2px red outline with a 2px offset, and focused
  links also get an underline and a yellow highlight. The outline measures
  5.89:1 on white and 5.73:1 on the yellow highlight (`#c00`), above the 3:1
  non-text floor.
- The draft flag pairs its red-on-yellow color with the word "draft".
- Visited links are classic purple (`#551a8b`, 11.01:1 on white, 10.46:1
  on the panel grey); unvisited blue `#00c` is 10.66:1 on the panel. The
  current page in the Node Tracker is bold on the yellow highlight and
  carries `aria-current="page"`.
- Aside kinds keep their word in a white-on-colour title bar like the
  nodelets: note `#555` 7.46:1, tip `#063` 7.12:1, info `#036` 12.61:1,
  warning `#7a4a00` 7.48:1, danger `#a00` 7.75:1. Danger also has a 2px
  red frame.
- The breadcrumb is an inline `A > B` trail; the `>` separators are
  decorative (empty alternative text) and the current crumb is bold.
- Prose is capped at a 39rem measure (about 85 characters at 12px) while
  the nodelet column keeps its fixed width. The Writeups heading is hidden
  when the node has no children.
- The dense 12px layout is responsive and collapses its nodelets below 700px.
- Reduced-motion preferences disable transitions and smooth scrolling.
- `@media print` drops the skip link and nodelets, flattens the grid, removes
  the top-bar fill, and wraps code blocks.
- The on-page TOC nodelet, the status/parent/tags header, the Writeups
  list, and the `graph-links` relations/backlinks wrapper are
  `data-boris-search-exclude`, so none of them enter the rendered-search
  index.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
