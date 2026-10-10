# Accessibility notes

What the HTML 4.01 Strict compatibility theme guarantees, checked against the
built output (`--target-profile default=html4-strict`) and
`assets/css/site.css`. The README records which gaps the profile forces.

- The first link on every page is "Skip to content", pointing at
  `#boris.main` (the `div.page` content wrapper). It is off-screen until it
  receives focus. Strict markup cannot make the target focusable with
  `tabindex`.
- Links get a 2px `:focus` outline in every browser, plus a 3px offset
  `:focus-visible` outline where supported. `#174781` measures 9.31:1 on the
  white page, above the 3:1 non-text floor.
- Body text is `#18212a` on `#fff`. The theme uses no color-only signals.
- There are no HTML5 landmarks or ARIA attributes; the profile forbids them.
  Structure comes from heading order and classed `div`s in a fixed reading
  order: skip link, navigation, breadcrumb, content, TOC, metadata,
  relations, backlinks, children.
- Details blocks are always expanded (no native disclosure), so no content
  is hidden behind an interaction.
- There is no JavaScript and no motion. A `prefers-reduced-motion` guard is
  present anyway.
- `@media print` hides the skip link, navigation, and TOC, removes width
  caps, and wraps code blocks.
- No search UI ships: `data-boris-search-*` hooks are outside the Strict
  vocabulary.

The profile contract states that neither Boris nor this theme claims
accessibility conformance. This is a theme-level pass. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.
