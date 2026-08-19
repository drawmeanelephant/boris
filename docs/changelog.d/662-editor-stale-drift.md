# Editor: stale problems also when line-number drift shifts them (#662)

A20 (#660) marked a problem possibly-stale when its own line changed, but
missed **line-number drift**: inserting or deleting lines *above* a problem
shifts what its reported line number addresses — even when the text now at
that line happens to match (e.g. adjacent identical lines). The derivation
now also marks a problem when the buffer's line count changed and the first
divergence from `baseline` sits strictly above the problem's line.

- Pure modifications above — line count unchanged — still never mark (A20's
  pinned "editing a different line" behavior): the problem's line number
  still addresses the same text.
- Deletions below the problem's line never mark; the caret-gating, the two
  surfaces (pane card + Source pane inline list), and the clearing semantics
  (caret move, save) are unchanged.
- The rule is a documented approximation: a rare mixed edit (modification
  above plus a count change below) may over-mark, which errs toward honesty —
  the mark clears on save.

Pinned by two Playwright cases (deleting a line above marks even with
matching text; deleting lines below never marks) alongside the existing A20
cases; suite is 111/111. Shell-only — no host or compiler change.
