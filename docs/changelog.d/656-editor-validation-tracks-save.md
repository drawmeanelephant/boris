# Editor: validation tracks the newest save (#656)

The editor's validation feedback now follows the newest save instead of
lagging behind the daemon's debounce plus a 1 s poll tick.

- The host records every successful file op (save / create / rename / delete)
  and a validate demand that lands within 3 s of one waits — bounded, also 3 s
  — for the daemon's save-triggered cycle to rewrite the report, so a manual
  *Validate project* clicked right after a save answers from after the change,
  never before. With no pending cycle there is zero added latency.
- On the shell side a successful save fires the existing cycle-aware problems
  refresh on a 300 ms trailing debounce (rapid saves coalesce), so the
  problems surface updates with the save rather than on the next poll tick.
- One-shot fallback is unchanged: no daemon means no pending-cycle wait and no
  save-triggered refresh.

Pinned by a new host unit test (`noteSave`/pending-cycle decision), a new
`test-validation-daemon.sh` step (immediate validate after a host create
returns the new `EDUPLICATEID` failure state), and two Playwright cases
(save-triggered refresh on the daemon path; none on the one-shot path);
editor host tests 46/46, e2e 104/104.
