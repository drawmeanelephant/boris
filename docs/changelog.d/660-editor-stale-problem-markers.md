# Editor: mark problems possibly-stale at the caret (#660)

A19's global "problems reflect saved files" caveat was coarse: a problem
whose own source region is untouched stays accurate while the user edits
elsewhere, and a problem at the exact line being rewritten is silently stale.
The editor now marks per-problem staleness, shell-side only:

- While the open buffer is dirty, the buffer is compared line-by-line against
  `baseline` (the last loaded/saved content, i.e. the report-time snapshot).
- A problem is marked **"Possibly stale — the open buffer changed this region
  since the report."** when it belongs to the open file, has a reported
  position, the caret's line equals the problem's line (with the caret at or
  after the problem's column, when reported), and that line's text changed.
- The mark appears in the problems-pane card and the Source pane's inline
  problem list, and clears when the caret leaves the region or the buffer is
  saved. Problems in other files, problems without positions, and untouched
  regions are never marked; line-number drift from edits on earlier lines is
  explicitly out of scope.

The derivation reads only buffer/report state, so one-shot and daemon hosts
behave identically. Pinned by two Playwright cases (mark shows on the
rewritten line at the caret, clears on caret move and on save; a change on a
different line never marks, on the daemon path); suite is 109/109.
