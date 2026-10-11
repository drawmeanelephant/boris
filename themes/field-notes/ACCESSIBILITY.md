# Accessibility notes

What Field Notes guarantees, checked against the built output and
`assets/field-notes.css`. The notebook look is CSS over real landmarks and
generated links — punched binding, grid paper, and stamps are decoration;
the structure underneath is ordinary HTML.

- Every layout starts with a skip link to `main#content` (`tabindex="-1"`),
  and each page keeps `header`, `main`, and `footer` landmarks. The margin
  column and leg-entries sections are labelled; the compiler's own
  `nav aria-label="Site"`, `"Breadcrumb"`, `"Children"`, and `"On this
  page"` landmarks survive inside them.
- `:focus-visible` is a 2px outline in `--focus` with a 3px offset:
  `#1d5fa8` on the leaf measures ~6.3:1, and the headlamp `#8fc4f0` on
  `#2a271e` ~8.2:1. The outline is the cue, not color alone.
- Contrast (calculated from the stylesheet's sRGB values). Light leaf:
  `--ink` `#38352d` on `#fbf7e8` ~10.4:1; `--pencil` `#6f695c` ~4.6:1 and is
  used only for labels, field names, and furniture; links `#b6471a` ~5.3:1;
  visited `#75563b` ~6.4:1. Dark leaf: `--ink` `#e8e2cf` on `#2a271e`
  ~11.9:1; links `#ffab7a` ~7.4:1; `--pencil` `#a39a83` ~5.6:1.
- The status stamp prints the status as text (`{{page-status}}`) inside a
  rotated border — readable, not color-only. The same status also appears
  as plain text in the entry's field line via `{{metadata}}`, so state is
  never carried by the stamp alone.
- Callouts keep explicit text titles drawn in their kind color plus a full
  border and left edge — three redundant cues, never color alone.
- Log lines are ordinary links inside the compiler's
  `nav aria-label="Children"`. The "entry NN" numbers are CSS counters and
  the "turn to" hint has an empty accessibility alternative; the accessible
  name is the real page title. The current entry in the logbook index keeps
  `aria-current="page"` plus a left edge and weight change.
- **The whole logbook** on the cover and callout details are native
  `details`/`summary` — keyboard-operable with no script.
- The punched binding holes, binding rule, and grid paper are CSS
  backgrounds and borders on the leaf — pure decoration over the document,
  nothing interactive hidden under them.
- `prefers-color-scheme: dark` swaps to the headlamp palette;
  `prefers-reduced-motion: reduce` disables smooth scrolling and the stamp
  rotation is removed in print.
- Under 52rem the margin column moves below the leaf instead of
  truncating; tables and code scroll locally rather than forcing a minimum
  body width.
- The cover band, field lines, margin column, log lines, cross-references,
  and footer carry `data-boris-search-exclude`; only author prose is
  indexed. The theme supplies no browser search client.
- `@media print` removes the cover band, margin column, logbook index,
  footer, and binding furniture; flattens the leaf to black on white; and
  wraps code blocks.

This is a theme-level pass with calculated contrast, not a screen-reader
certification. Review a real author's content for keyboard, zoom, image
descriptions, and reading order before publication.
