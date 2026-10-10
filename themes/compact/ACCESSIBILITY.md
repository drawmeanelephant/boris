# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Both layouts open with "Skip to content" targeting
  `#main-content`, a `main` with `tabindex="-1"`.
- **Landmarks.** A `banner` header, a labelled navigation rail, one `main`,
  a labelled "On this page" rail, and a `contentinfo` footer.
- **Focus.** `:focus-visible` draws a 3px outline with a 3px offset:
  `#a94a00` is 5.73:1 on white surfaces (light); `#ffd08a` is 11.13:1 on the
  dark surface `#1a241e`.
- **Contrast.** Links `#197149` are 6.00:1 on white and 5.44:1 on the soft
  surface; dark links `#8cddb0` 9.95:1. Muted metadata text was darkened to
  `#606c65` (4.97:1 on the soft metadata strip; the previous `#68746d`
  measured 4.42:1). Relation kind tags are 11.61:1 (light) and 8.61:1 (dark).
- **Not colour alone.** Callouts keep a text title; relation kinds are words.
- **Motion.** The theme has no animation; `prefers-reduced-motion: reduce`
  disables smooth scrolling.
- **Print.** `@media print` forces black on white even for dark-mode
  readers, hides the skip link, rails, and footer, drops the panel border,
  and wraps code.
- **Narrow screens.** The three-column grid drops the outline rail under the
  article at 58rem and becomes one column at 42rem; nested navigation levels
  collapse but stay reachable through the breadcrumb and children list.
- **Search hygiene.** `data-boris-search-root` on `main`; rails live outside
  it; the outline rail, children panel, and relations wrapper carry
  `data-boris-search-exclude`.
