# Accessibility notes

What Tokens guarantees, checked against the built output and
`assets/css/tokens.css`. Tokens uses real landmarks, native disclosures, and
generated links — the spec-sheet look is CSS, not a simulated application.

- Every layout starts with a skip link to `main#content` (`tabindex="-1"`),
  and each page keeps `header`, `main`, and `footer` landmarks. The catalog
  column and register sections are labelled; the compiler's own
  `nav aria-label="Site"`, `"Breadcrumb"`, `"Children"`, and `"On this page"`
  landmarks survive inside them.
- `:focus-visible` is a 2px outline in `--focus` with a 3px offset: `#1a5fb4`
  on the light sheet measures ~5.9:1, and the dark blueprint `#9ecfff` on
  `#122a3f` measures ~8.9:1. Focus is never color-only — the outline itself
  is the shape change.
- Contrast (calculated from the stylesheet's sRGB values). Light: `--ink`
  `#22201b` on `--sheet` `#fffef9` is ~14.3:1; `--ink-soft` `#6b675c` is
  ~4.8:1 and is used only for labels and furniture, never sentences; links
  `#b0431f` are ~6.4:1 on the sheet; visited `#6d4a9e` ~6.0:1. Dark:
  `--ink` `#d7e4f2` on `#122a3f` ~11.7:1; links `#ffcf6e` ~9.4:1;
  `--ink-soft` `#8ca6bd` ~5.2:1.
- The masthead token strip and the cover's working-set band are
  `aria-hidden`: they restate values the stylesheet already owns, so nothing
  is communicated by color alone. Signal chips in prose are ordinary table
  cells next to the token name and hex value in text.
- Callouts keep their text titles drawn in the kind token: note `#2b5f8a`
  (~5.7:1 on paper), tip `#2f6b4f` (~5.4:1), warning `#8a5a00` (~5.2:1),
  danger `#a02515` (~5.9:1); dark equivalents `#7fc4ff`, `#7fd6a4`,
  `#ffc078`, `#ff9b8a` all exceed 5:1 on the blueprint sheet. Each callout
  keeps a colored left edge plus its label — never color alone.
- A `status: draft` page gets a dashed sheet border and a printed DRAFT
  stamp; the same status remains as text in the spec table (`{{metadata}}`),
  so the state never depends on noticing the stamp.
- Register entries are ordinary links inside the compiler's
  `nav aria-label="Children"`. Row numbers are CSS counters and the "see
  sheet" hint has an empty accessibility alternative; the accessible name is
  the real page title. The catalog's current entry keeps
  `aria-current="page"` plus a left accent edge and weight change.
- The cover's **Full catalog index** and callout details are native
  `details`/`summary` elements — keyboard-operable with no script.
- `prefers-color-scheme: dark` swaps to the blueprint palette;
  `prefers-reduced-motion: reduce` disables smooth scrolling, the only
  motion the theme has.
- The catalog column drops below the sheet under 52rem instead of
  truncating; sheets, tables, and code scroll locally rather than forcing a
  minimum body width.
- The catalog column, sheet path, register, spec table labels, working-set
  band, cross-references, and footer furniture carry
  `data-boris-search-exclude`; only author prose is indexed. The theme
  supplies no browser search client.
- `@media print` removes the masthead, tick ruler, catalog column, cover
  index, working set, and footer; flattens the sheet to plain black on
  white; and wraps code blocks.

This is a theme-level pass with calculated contrast, not a screen-reader
certification. Review a real author's content for keyboard, zoom, image
descriptions, and reading order before publication.
