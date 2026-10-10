# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Every layout opens with "Skip to content" targeting
  `#main-content`, the `<main tabindex="-1">` of that layout, so focus moves
  into the page body.
- **Landmarks.** A `banner` header, a labelled navigation `aside` or `nav`,
  one `main`, and a `contentinfo` footer on every layout. Navigation,
  breadcrumbs, the outline, children, and relations are ordinary links.
- **Focus.** `:focus-visible` draws a 3px solid outline with a 3px offset.
  Light palette `#c2410c`: 5.06:1 on the panel surface `#fffcf7`, 4.59:1 on the
  canvas. Dark palette `#fbbf24`: 10.48:1 on `#1c1917`. Disclosure summaries
  use an inset ring of the same colour.
- **Contrast.** Body text is `#1c1917` on `#fffcf7` (light) and `#f5f5f4` on
  `#1c1917` (dark). Links are `#0f766e` (5.35:1) and `#2dd4bf` (9.39:1) on
  the panel surface. Relation kind pills are 5.39:1 (light) and 6.38:1 (dark).
- **Not colour alone.** Callouts keep a text title. Relation kinds are text
  ("depends on"), not a colour code. Links keep an underline in prose.
- **Motion.** `prefers-reduced-motion: reduce` turns off smooth scrolling,
  the skip-link slide, and the disclosure-arrow rotation.
- **Print.** `@media print` forces the light palette even when the reader
  uses dark mode, hides the skip link, the navigation and outline rails, and
  the footer, collapses to one column, and keeps relations and backlinks.
- **Narrow screens.** The three-column shell stacks at 54rem; nothing is
  hidden except nested navigation levels, which stay reachable from the
  breadcrumb and children lists.
- **Search hygiene.** `data-boris-search-root` sits on `main`. Navigation and
  outline rails live outside it. The relations wrapper carries
  `data-boris-search-exclude` so linked page titles are not indexed as this
  page's text; the compiler already excludes `dl.page-metadata`.
