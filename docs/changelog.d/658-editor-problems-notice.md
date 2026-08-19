# Editor: the problems pane names "no report yet" vs "no problems" (#658)

An empty Problems pane was ambiguous: a tree that was never validated looked
identical to one whose newest report has zero problems. The pane now names its
own empty states, derived purely from state the host already sends:

- **No report yet** — daemon path: `validate-state` `idle` (never spawned) or
  `running` (first cycle in flight) → *"No validation report yet. Run
  Validate project to start the daemon."*; one-shot path: no command has ever
  run → *"No validation report yet. Run Validate project to check the tree."*
- **Newest report is clean** — daemon path: `success` with `problems_count 0`
  → *"No problems in the newest report (cycle N)."* (the cycle counter names
  the report); one-shot path keeps the existing command-generic clean line.

The notice only renders when the pane has nothing to list and the last
command was validate (or none), so it can never contradict another command's
problem list, and a clean-report claim carries the same saved-files caveat as
a problem list when the buffer is dirty. A side hardening: the problems pane
no longer shrinks below its content at wide viewports, which had spilled the
command bar under the preview heading and covered clicks on its boundary
buttons.

Pinned by three Playwright cases (idle → running → clean transitions, the
one-shot notice + clean line, and the notice stepping aside for a non-validate
command); suite is 107/107. Shell-only — no host or compiler change.
