### Changed

- The editor shell has one visual vocabulary over its tokens — a single button
  system (primary, secondary, danger, ghost), badge, notice, empty state, card,
  toolbar, and row list — and every pane now renders a designed loading,
  unavailable, empty, stale, or `build_required` state instead of incidental
  text. Panes no longer claim "no files", "no profile", or "no Proof Pack"
  before the host answers (or when it never does), warning-severity problems
  stop rendering as errors, and a startup `stale` preview reads as a warning
  rather than a failure. Two contrast defects are fixed: the Publication
  **Run publication plan** label inherited muted ink on the accent fill, and
  light-theme key-hint chips on primary buttons were white on near-white.
  `check-scales.mjs` now fails any absolute length in a type, spacing, or
  corner property of `styles.css`. No host endpoint or contract changed.
  Links: [the editor README](/editor/README.md#component-vocabulary-and-state-honesty),
  [issue #1044](https://github.com/drawmeanelephant/boris/issues/1044).
