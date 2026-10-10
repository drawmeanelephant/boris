# Accessibility notes

What Cards guarantees, checked against the built output and
`assets/css/cards.css`.

- A skip link to `#content` is the first focusable element. `#content` is the
  `main` card (`tabindex="-1"`).
- The page uses `header`, `aside` (the TOC rail is labelled "On this page"),
  `main`, and `footer`. Relations and backlinks keep their compiler
  `aria-label`s and gain visible headings from the theme.
- `:focus-visible` draws a 3px outline with a 3px offset. Measured: 5.06–5.43:1
  in light mode (`#b54708` on `#f5f7fb`/`#fff`) and 10.8–11.8:1 in dark mode
  (`#ffcb66` on `#172033`/`#111827`), above the 3:1 non-text floor.
- `prefers-color-scheme: dark` swaps the full palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, animations,
  and transitions.
- `@media print` drops the skip link and rails, removes card chrome, and wraps
  code blocks.
- The TOC rail, the "In this section" card, and the `graph-links`
  relations/backlinks wrapper are `data-boris-search-exclude`; compiler
  metadata stays out of the rendered-search index.

- Visited links shift to violet (`#5a48b8`, 6.88:1 on the card, 6.11:1 on
  the muted surface; `#c4b5fd`, 8.81:1 on the dark card). The current page
  in the nav has a tinted pill and bold weight as well as
  `aria-current="page"`.
- Aside kinds keep their uppercase word and add a coloured edge and title:
  tip `#1f7a4d` (4.74:1 on its tint), info `#315fd4` (4.81:1), warning
  `#b54708` (4.99:1), danger `#b42318` (5.75:1, plus a full red border); in
  dark mode the titles measure 5.56–9.44:1 on the muted surface.
- Below 42rem the navigation keeps the whole tree: top-level entries stack,
  and each entry's children wrap as an indented row under it, so nested
  pages stay reachable from the nav itself. The "In this section" card hides
  when a page has no children.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
