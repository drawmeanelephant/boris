### Added

- The `pr-issue-close` lint can now be driven offline: `--pr` and `--body-file`
  share one verdict path, and `ISSUE_CLOSE_LINT_FIXTURE=<path>` supplies issue
  states in place of the API, so a body is judged with no network and no `gh`.
  The grammar self-test uses that seam to run the real entry point as a
  subprocess, pinning the inert-vs-live matrix — report text, class guard, and
  exit codes — in 61 cases under macOS `bash` 3.2. A number the fixture omits
  is an error rather than a skip, so a fixture typo cannot turn a real violation
  into a passing test. Links:
  [the lint](/scripts/check-pr-issue-close.sh),
  [the CI lane](/.github/workflows/ci.yml).
