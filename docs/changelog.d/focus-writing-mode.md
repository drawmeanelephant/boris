### Added

- The editor UI gains a focus writing mode: a full-screen, word-processor
  style surface for the open buffer with Write / Split / Preview layouts
  (choice persisted per browser), typography controls (text size
  S/M/L/XL, reading measure Narrow/Medium/Wide, and a Serif/Sans
  typeface toggle, persisted and validated on load), a live reading aid
  that renders the bounded Markdown subset an author types (headings,
  paragraphs, emphasis, code fences, quotes, lists, wiki links, and Aside
  tokens) with honest non-navigable wiki links, full escaping, and a
  frontmatter block that renders as a muted collapsed band rather than
  body text, word
  count and caret status, and entry/exit from the Source pane's Focus
  button or the command palette. Opt-in writing aids (persisted and
  validated on load): typewriter scrolling keeps the typed line
  vertically centered, and paragraph dimming veils everything but the
  caret's paragraph through a masked overlay. The overlay edits the
  shared buffer, so
  undo/redo, recovery snapshots, conflict handling, and saves are the
  shell's existing machinery — see [the editor README](/editor/README.md).
