# Accessibility notes

What Columns guarantees, checked against the built output and
`assets/css/columns.css`. The newspaper dressing is CSS only — the
document stays ordinary HTML: a labelled `main`, the compiler's own
`nav` landmarks, real lists, and native `details`/`summary`.

- Every layout starts with a skip link to `#content`, the `main` element
  (`tabindex="-1"`, so focus lands on it in every browser).
- Reading order is document order: masthead → story header → prose →
  story jumps → wire → rail. The CSS multi-column flow in `.prose` does
  not change DOM order; browsers and readers traverse the source.
- The masthead breadcrumb is the compiler's `nav aria-label="Breadcrumb"`;
  the section listing is `nav aria-label="Site"`; the TOC keeps
  `nav aria-label="On this page"`. The theme adds no shadow landmarks.
- `{{page-status}}` prints as real text in the press stamp; `draft`
  picks up the accent color in addition to its label, never color alone.
- Contrast (light): ink `#1d1a14` on paper `#f6f2e7` is 15.5:1; soft ink
  `#544d3f` on paper is 7.5:1; accent `#8c1d18` on paper is 8.2:1. The
  `.press-line` edition strip is the smallest text on the page at 0.72rem
  and still measures 7.5:1.
- Contrast (dark, "late city edition"): ink `#ece5d4` on `#211e18`
  is 13.2:1; soft ink `#b3a98f` is 7.1:1; accent `#d9706a` on `#211e18`
  is 5.1:1.
- `:focus-visible` is two-tone: a 0.18rem accent-gold (`#b98a1d`) outline
  outside a 0.24rem ring in the text color. The ink ring carries the
  contrast in both modes; the gold alone is decoration.
- The current section in the desks bar is drawn with a 2px accent
  underline (`aria-current="page"`), a decoration change and not color
  alone.
- Justified + hyphenated columns are a visual reflow of the same source;
  `column-span: all` on `h1`/`h2` is progressive enhancement — engines
  without it keep headings inside their column, legible but narrower.
- Empty furniture removes itself: the rail, the wire, the jumps list, and
  each rail block are `display: none` when the compiler emits no items,
  so no empty landmarks or borders are announced.
- `prefers-color-scheme: dark` runs the late city edition.
  `prefers-reduced-motion: reduce` turns off smooth scrolling, the only
  motion the theme has.
- `@media print` keeps the two-column article set and the press stamp,
  drops the desks bar, rail, colophon, skip link, and press line, and
  forces black ink on white.
- The rail, the jumps/edition lists, layout rubrics, the press stamp, the
  credit line, and the wire block are `data-boris-search-exclude`; layout
  furniture stays out of the rendered-search index. `{{title}}` is spent
  on the document `<title>`; the authored `h1` headlines each page and
  titles it in `_boris/search/search-index.json` (verified).

This is a theme-level pass. It does not replace a manual screen-reader,
keyboard, zoom, or contrast review of a rendered site.
