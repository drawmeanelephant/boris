# Accessibility notes

What the HTML 4.01 Strict theme guarantees, checked against the built output
(`--target-profile default=html4-strict`) and `assets/css/site.css`. The
README records which gaps the profile forces. Contrast ratios are WCAG 2.x
values computed for this palette (2026-10-11).

- The first link on every page is "Skip to content", pointing at
  `#boris.main` (the `div.page` content wrapper). It is off-screen until it
  receives focus, then appears as an ink block in the top-left corner.
  Strict markup cannot make the target focusable with `tabindex`.
- Reading order is the DOM order: skip link, rail (site navigation, then the
  page outline), breadcrumb, content, metadata, relations, backlinks,
  children. Structure comes from heading order and classed `div`s; there are
  no HTML5 landmarks or ARIA attributes — the profile forbids them.
- Body text is `#1a1a1a` on `#fff` (17.4:1). Links are `#d5281b` (5.06:1,
  above the 4.5:1 AA text floor) with a partial-red underline; visited links
  are `#7d1810` (10.45:1) — visited and unvisited differ in lightness as
  well as the hover/focus states. Muted labels (`#595959`) measure 7.0:1;
  blockquote text `#4d4d4d` is 8.45:1; code text sits on `#f4f4f2` at
  15.8:1.
- Aside titles on their tints: note/info `#174781` on `#eef2f6` 8.28:1, tip
  `#24622a` on `#eef5ec` 6.62:1, warning `#7f4b00` on `#fbf3e0` 6.53:1,
  danger `#9b1c1c` on `#faeaea` 6.99:1. Every Aside keeps its word title, so
  the theme uses no color-only signals. The red squares (title mark, list
  markers, TOC numbers, details fold) are decorative and always accompany
  text or structure.
- `::selection` is white on `#d5281b` (5.06:1).
- Links get a 2px ink `:focus` outline in every browser, plus a 3px offset
  red `:focus-visible` outline where supported. Chrome links are ink and
  underline only on hover, so the red text floor is never the sole
  distinguishing state.
- Details blocks are always expanded (no native disclosure), so no content
  is hidden behind an interaction.
- There is no JavaScript and no motion. A `prefers-reduced-motion` guard is
  present anyway.
- `@media print` hides the skip link and the rail (navigation and page
  outline), removes width caps, prints links black and underlined, and
  wraps code blocks.
- No search UI ships: `data-boris-search-*` hooks are outside the Strict
  vocabulary. The same rule means the layout cannot mark chrome as
  search-excluded. The compiler drops the Strict slot chrome by class, so
  the only chrome text indexed is the skip link (see the README).

The profile contract states that neither Boris nor this theme claims
accessibility conformance. This is a theme-level pass. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.
