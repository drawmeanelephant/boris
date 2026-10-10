### Changed

- Focus writing mode's Typography and Writing aids panels open as overlays
  under their summaries instead of expanding inside the header, so opening one
  no longer reflows the chrome or shrinks the writing surface. They stay native
  disclosures with their saved preferences, and act as one light-dismiss menu:
  opening one closes the other, a click outside closes it, and Esc closes the
  open panel (focus returns to its summary) before a second Esc exits focus
  mode. The panel sits on one new stacking step, `--layer-focus-popover`, in
  the editor's declared layer ladder. Links: [the editor
  guide](/editor/README.md#focus-writing-mode),
  [#1066](https://github.com/drawmeanelephant/boris/issues/1066).
