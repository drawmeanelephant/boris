# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** "Skip to content" targets `#main-content`, a `main` with
  `tabindex="-1"`.
- **Landmarks.** A body-level `header` containing the search form
  (`role="search"`, a labelled input, a polite live status), a navigation
  `aside` whose menu is a native `<details>` disclosure, one `main`, a
  labelled "On this page" `aside`, and a footer.
- **Palette.** One light palette only; there is no dark variant to verify.
- **Focus.** `:focus-visible` draws a 2px outline in the primary colour with
  a 2px offset: `#003d9b` is 9.31:1 on the surface `#f8f9fb`. Anchored
  headings carry `scroll-margin-top` so a fragment jump is not hidden under
  the fixed header.
- **Contrast.** Body text `#191c1e` on `#f8f9fb`; secondary text `#434654`
  8.89:1; links `#003d9b` 9.31:1; outline-grey labels `#737685` 4.51:1 on
  white.
- **Links are visible.** The base reset removes link colour and underline;
  links inside page content and relations are restored to the primary colour
  with an underline.
- **Search.** The inline consumer shows a result count in the live status;
  the results list is now displayed whenever it has entries (it was
  permanently `display: none`). Without JavaScript a `<noscript>` note
  points to the menu.
- **Motion.** `prefers-reduced-motion: reduce` removes every animation and
  transition, including the card lift.
- **Print.** A clean single-column document (see the README): chrome is
  removed, type is set in points, headings stay with their first line, list
  bullets are kept, and external link URLs are printed. Verified by printing
  a CV-shaped page to PDF from headless Chrome.
- **Narrow screens.** Below 1024px the navigation stacks above the content;
  below 1280px the outline rail is hidden because the breadcrumb and
  children list remain.
- **Search hygiene.** `data-boris-search-root` on `main`; the outline rail
  and relations wrapper carry `data-boris-search-exclude`.
