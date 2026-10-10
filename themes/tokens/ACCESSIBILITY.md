# Accessibility notes

What Tokens guarantees, checked against the built output and
`assets/css/tokens.css`.

- Every layout starts with a skip link to `#main-content`, the `main`
  element (`tabindex="-1"`, so focus lands on it in every browser).
- `:focus-visible` is two-tone: the theme's 0.2rem amber (`#fab005`) outline sits outside a
  0.2rem ring in the text color. The ink ring carries the contrast:
  14.5:1 in light mode (`#20212d` on `#f5f4f0`) and
  15.9:1 in dark mode (`#f6f3ea` on `#19181d`). The
  accent alone measures 1.7–1.8:1 on the light background, which is
  why the ring is there; it measures 9.5:1 in dark mode.
- `prefers-color-scheme: dark` swaps the palette.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` drops the skip link, header, footer, and rails; flattens the grid;
  forces black on white; and wraps code blocks.
- Relations and backlinks keep their compiler `aria-label`s and gain visible
  headings from the theme.
- The TOC rail is `data-boris-search-exclude`; compiler metadata stays out of
  the rendered-search index.

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
