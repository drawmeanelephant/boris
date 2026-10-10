# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** "Skip to content" targets `#main-content`, a `main` with
  `tabindex="-1"`.
- **Landmarks.** The layout uses `header` (banner), `nav`, `main`,
  `article`, `section`, `aside`, and `footer` landmarks.
- **Text userpic.** The userpic is text with an explicit accessible label,
  not a decorative image.
- **Palette.** One dark palette (`color-scheme: dark`). White `#fff` on
  black is 21:1; the signal green `#00ff00` is 14.43:1 on the `#0a0a0a`
  panel; quiet text `#999` is 6.95:1. Verify again if the theme is recoloured.
- **Accent kinds.** Aside kinds keep their bracketed word (`[NOTE]`,
  `[WARNING]`…) and add a hue on the `#0a0a0a` panel: cyan `#00e5ff`
  12.87:1 (tip), amber `#ffb000` 10.81:1 (warning), red `#ff6b6b` 7.13:1
  (danger, which also gets a full red border). Visited links are a dimmer
  green `#7bc67b` (10.21:1 on black) with a dashed underline, so the state
  is not colour alone.
- **Headings.** The `system.log` banner is a paragraph, not a heading: the
  entry's own `h1` is the page's only top-level heading. Content headings
  show their Markdown level (`##`, `###`) as decorative text with empty
  alternative text.
- **Breadcrumb.** An inline `pwd:` trail; the `pwd:` prefix and `/`
  separators are decorative (empty alternative text), and the current page
  keeps `aria-current="page"`.
- **Focus.** `:focus-visible` draws a 2px signal-green outline with a 3px
  offset; focused links also switch to inverse video (black on green), so
  focus never relies on the outline alone.
- **Not colour alone.** Links keep underlines; the draft status is inverse
  video plus its word; relation kinds print as bracketed tokens.
- **Motion.** `prefers-reduced-motion: reduce` disables smooth scrolling and
  transitions.
- **Print.** `@media print` swaps the palette to black on white so the page
  does not print white ink on paper, removes the frame and inverse-video
  fills, hides the skip link, navigation, and outline, and wraps code.
- **Narrow screens.** Below 560px the entry header stacks without hiding
  content or navigation.
- **Search hygiene.** `data-boris-search-root` on `main`. The breadcrumb
  strip, entry header (kicker, userpic, metadata, tags), relations block,
  children section, and outline carry `data-boris-search-exclude`.
