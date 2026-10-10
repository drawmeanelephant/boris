# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Every layout opens with "Skip to content" targeting
  `#main-content`, a `main` with `tabindex="-1"`.
- **Landmarks.** A body-level `header` (banner), one `main`, a body-level
  `footer` (contentinfo), and labelled side rails ("Site navigation",
  "All pages", "Section navigation").
- **Focus.** `:focus-visible` draws a 3px solid outline in the primary
  colour with a 3px offset: `#6419e6` is 7.44:1 on white cards and 6.64:1
  on the page background; dark `#a78bfa` is 6.53:1 on dark cards. The skip
  link uses the secondary colour so it stands apart from its dark fill.
- **Contrast.** Body text `#1d1635` on white; links in the primary colour
  (above). Badge text is mixed toward the ink so every badge clears 4.5:1:
  draft/blog 5.48:1, published/section 5.19:1, tags 5.59:1, archived
  4.91:1 (light); 5.06:1 or better in dark mode. Aside title badges mix the
  kind colour 55% into the ink on a 14% kind tint: light note/info 7.63:1,
  tip 6.57:1, warning 7.73:1, danger 7.53:1; dark note/info 6.08:1, tip
  6.84:1, warning 6.02:1, danger 5.84:1.
- **Not colour alone.** Status badges and relation kinds keep their words;
  callouts keep a text title.
- **Motion.** The theme ships no animation. `prefers-reduced-motion:
  reduce` still clamps any transition or animation and turns off smooth
  scrolling, so later additions inherit the floor.
- **Print.** `@media print` resets the palette to black on white even for
  dark-mode readers, hides the skip link, side rails, home site map, and
  footer, removes card chrome, and wraps code.
- **Narrow screens.** Every grid collapses to one `minmax(0, 1fr)` column
  below 54rem, so wide code and tables scroll inside the card instead of
  pushing the page sideways at 390px; nothing is hidden.
- **Search hygiene.** `data-boris-search-root` on `main`; children panels,
  outline, in-main rails, and the relations wrapper carry
  `data-boris-search-exclude`; the compiler already excludes
  `dl.page-metadata` and `ul.page-tags`.
