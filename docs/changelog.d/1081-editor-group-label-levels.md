### Fixed

- Editor: Graph and Publication group labels no longer skip a heading level —
  the `.group-label` role renders as `h3` under a pane title and `h4` under a
  sub-pane title, so screen-reader heading navigation reads `h2 → h3 → h4`
  with no gap. Links: [editor reading hierarchy](/editor/README.md),
  [issue #1077](https://github.com/drawmeanelephant/boris/issues/1077).
