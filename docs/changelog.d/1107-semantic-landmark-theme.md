### Changed

- The `semantic` theme is now a landmark-first documentation theme with its own
  point of view: the page's structure is the surface. Every region names itself
  in a small monospace label — `header`, `main`, `article`, `section`, `nav`,
  `footer` — every heading carries its level in the left margin, and callouts,
  disclosure, tables, and definition lists are the platform elements styled in
  place. The banner drops the hero-card and badge skeleton; the home page becomes
  a contents page whose two-column deck is the graph's first level of real child
  links; the footer is a quiet colophon instead of self-narration. Light and dark
  palettes follow the operating system, `prefers-reduced-motion` pins the only
  motion the theme has, and print drops the labels and the rails. The decorative
  region and heading labels are CSS generated content given an empty accessible
  name, so a screen reader announces the real landmark or heading level and the
  label stays visual. Presentation only — the layouts keep every existing slot,
  the content model and config schema are unchanged, the published pages stay
  JavaScript-free and offline, and the layout authors no heading of its own so a
  page has exactly one `<h1>`, the one the content provides. The theme ships a
  small, complete specimen under `themes/semantic/specimen/` that demonstrates
  landmarks, heading hierarchy, and native components on its own content graph.
  See [the Semantic theme](/themes/semantic/README.md), its
  [accessibility notes](/themes/semantic/ACCESSIBILITY.md), and the updated
  [theme matrix](/docs/init-theme-matrix.md).
