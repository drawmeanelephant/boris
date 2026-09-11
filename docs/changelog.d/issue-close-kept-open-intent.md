### Fixed

- The `pr-issue-close` lint no longer fails a pull request that names an open
  issue it intends to leave open. `Refs #N` / `Related to #N` is now a declared
  keep-open intent: the check accepts it, reports the issue to the reviewer, and
  GitHub never auto-closes it — so a parent or umbrella issue can be referenced
  without being force-closed by a merge. A bare `#N` mention still fails, since
  it declares neither intent. The grammar self-test grew to 42 cases. Links:
  [the PR template](/.github/PULL_REQUEST_TEMPLATE.md),
  [the lint](/scripts/check-pr-issue-close.sh).
