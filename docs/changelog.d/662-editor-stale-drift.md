### Added

- The editor's per-problem "possibly stale" mark now also covers **line-number
  drift** (#662, follow-on to #660): when the open buffer's line count changed
  and the first divergence from `baseline` sits strictly above a problem's
  line, the problem is marked possibly-stale even when the text at its
  reported line is unchanged (adjacent identical lines, so a deletion above
  slides the others into place). Deleting a line below never marks, and a
  pure modification above (line count unchanged) still never marks; the mark
  still clears on caret move or save. The rule is the documented approximation
  from [#662](https://github.com/drawmeanelephant/boris/issues/662): identical-line
  insertion above stays ambiguous from text alone. Shell-only — no host or
  compiler change. Pinned by two new Playwright cases (delete-above marks,
  delete-below never marks) alongside the existing A20 cases. See
  [the editor README](/editor/README.md).
