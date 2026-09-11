### Fixed

- The `pr-issue-close` lint now models GitHub's reference rules exactly, closing
  two ways a PR body could look correctly linked while landing nothing. `Refs #N`
  / `Related to #N` is accepted as a declared keep-open intent — the check
  reports the issue to the reviewer and GitHub never auto-closes it, so a parent
  or umbrella issue can be named without being force-closed by a merge — while a
  bare `#N` mention still fails for declaring neither intent. And a declaration
  written inside backticks or a fenced block now fails as INERT instead of being
  stripped away as if it were not there: GitHub does not linkify those regions,
  so an inert `Closes #N` closes nothing while reading exactly like a working
  one. This is the failure that orphaned issue #834 on 2026-09-11. The grammar
  self-test grew from 29 to 50 cases. Links:
  [the lint](/scripts/check-pr-issue-close.sh),
  [the PR template](/.github/PULL_REQUEST_TEMPLATE.md).
