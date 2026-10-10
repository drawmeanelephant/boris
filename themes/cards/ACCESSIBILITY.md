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
- The TOC rail is `data-boris-search-exclude`; compiler metadata stays out of
  the rendered-search index.

Known limitation: below 42rem the navigation shows top-level entries only
(nested lists are hidden by CSS). Breadcrumbs and the "In this section" card
still reach child pages.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
