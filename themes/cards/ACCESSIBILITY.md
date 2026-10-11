# Accessibility notes

Cards uses real links and native disclosures, not a simulated card application.

- The first focusable element is a skip link to `main#content`, which has
  `tabindex="-1"`. Both layouts have header, main, and footer landmarks.
- **Open the index** is a native `details` / `summary` disclosure. Its complete
  nested compiler nav remains available at every viewport width; it is not
  truncated to a single level. The open drawer scrolls within 70vh.
- **Find a line** is a second native disclosure containing the compiler outline.
  On narrow reading cards it expands in-flow instead of covering prose. Empty
  outlines and child decks are hidden; pages without metadata have no record.
- Child cards are ordinary links inside the compiler's labelled Children nav.
  Their entire sheet is clickable and keyboard-focusable. CSS counters and
  “Pull this card” labels have empty accessibility alternatives; the accessible
  link name stays the actual page title, not an invented id or repeated action.
- Links in prose are underlined. Current index entries retain
  `aria-current="page"`, bold weight, and a vertical edge. Visited card titles
  and links change tone. Aside kinds retain explicit text labels and edges;
  danger has a complete border as well.
- Focus has a 3px outline and 4px offset. Calculated WCAG contrast for
  `#164f74` on the light paper/desk/alternate surfaces is 7.42–8.58:1;
  `#a7d9ff` on dark surfaces is 7.56–10.50:1.
- Text contrast was calculated from the stylesheet's sRGB values. Across the
  three light surfaces, body text is at least 11.27:1, muted text 4.83:1,
  links 5.49:1, visited links 5.45:1, and Aside titles 5.45:1. Across dark
  surfaces, corresponding minima are 9.60:1, 6.43:1, 6.56:1, 6.55:1, and
  6.43:1. Colored file tabs are decorative, not the only label or state cue.
- `prefers-color-scheme: dark` changes the complete palette;
  `prefers-reduced-motion: reduce` disables the card-lift transitions.
- Layouts have no minimum body width. Deck columns wrap down to one card;
  long prose and titles wrap, and wide tables/code scroll locally.
- The search root contains the author prose. Index drawers, breadcrumbs, outlines,
  child decks, metadata records, and graph links have
  `data-boris-search-exclude`. The theme supplies no browser search client.
- Print forces a light sheet, removes navigation, outline, tab, filing records,
  footer, and graph furniture, flattens the child deck to linked titles, and wraps
  preformatted text. There is no additional print layout.

These are theme-level guarantees and calculated contrast measurements, not a
screen-reader certification. Review a real author's content for keyboard,
zoom, image descriptions, and reading order before publication.
