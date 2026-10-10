# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** "Skip to content" targets `#main-content`, a `main` with
  `tabindex="-1"`.
- **Landmarks.** A body-level `header`, a navigation `aside` whose menu is a
  native `<details>` disclosure (open by default, keyboard-operable without
  JavaScript), one `main`, a labelled "On this page" `aside`, and a footer.
- **Palette.** One light palette only; there is no dark variant to verify.
- **Focus.** `:focus-visible` draws a 2px outline in the primary colour with
  a 2px offset: `#00535b` is 8.35:1 on the surface `#fcf8f9`. Anchored
  headings carry `scroll-margin-top` so a fragment jump is not hidden under
  the fixed header.
- **Contrast.** Body text `#1b1b1c` on `#fcf8f9`; secondary text `#3e494a`
  8.83:1; links `#00535b` 8.35:1.
- **Links are visible.** The base reset removes link colour and underline;
  links inside page content and relations are restored to the primary colour
  with an underline, so they are not distinguished by context alone.
- **Motion.** `prefers-reduced-motion: reduce` removes every animation and
  transition.
- **Print.** `@media print` hides the skip link, fixed header, navigation,
  outline, and footer, removes the top offset, and lets content use the full
  page width in black on white.
- **Narrow screens.** Below 1024px the navigation stacks above the content
  instead of disappearing (it was previously `display: none`, which left no
  navigation at all); below 1280px the outline rail is hidden because the
  breadcrumb and children list remain.
- **Search hygiene.** `data-boris-search-root` on `main`; the outline rail
  and relations wrapper carry `data-boris-search-exclude`.
