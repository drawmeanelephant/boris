# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Both layouts open with "Skip to content" targeting
  `#main-content`, a `main` with `tabindex="-1"`.
- **Landmarks.** A `banner` header with the breadcrumb, one `main`, a
  labelled "Archive tools" `aside`, and a `contentinfo` footer.
- **Palette.** One light palette only (`color-scheme: light`); there is no
  dark variant to verify.
- **Focus.** `:focus-visible` draws a 3px accent outline with a 3px offset:
  `#a8482c` is 5.14:1 on the paper `#f5f1e9` and 4.09:1 on the warm corner
  gradient. Index cards invert on focus (paper on ink, 14.5:1) instead of
  drawing a ring, so the whole card reads as focused.
- **Contrast.** Ink `#20201d` on paper is 14.5:1; accent links 5.14:1;
  visited links `#6b4a5e` 6.74:1; muted labels `#726e66` 4.51:1. Aside and
  Details slips sit on card `#faf7f3`; their kind labels measure note/info
  `#3d5a6c` 6.83:1, tip `#4f6331` 6.22:1, warning (accent) 5.42:1, danger
  `#8a1f1f` 8.56:1 on the card.
- **Not colour alone.** Status keeps its word (the archived stamp is also
  reversed, not just recoloured); relation kinds are printed as words.
- **Motion.** The theme has no animation. `prefers-reduced-motion: reduce`
  still clamps transitions and animations and disables smooth scrolling.
- **Print.** `@media print` drops the gradient, hides the skip link, sidebar,
  and footer, collapses to one column, shrinks the display type, and turns
  the index cards into a plain underlined list.
- **Narrow screens.** Below 42rem the sidebar stacks under the note and the
  index cards become a single column. The stacked column is
  `minmax(0, 1fr)`, so code and tables scroll inside it instead of widening
  the page at 390px.
- **Search hygiene.** `data-boris-search-root` on `main`. The index
  masthead (whose `<h1 data-boris-search-title="layout">{{title}}</h1>` has
  no id and names the index document in search), section label, children,
  and relations carry `data-boris-search-exclude`; the compiler already
  excludes `dl.page-metadata`, `ul.page-tags`, and `nav.page-parent`.
