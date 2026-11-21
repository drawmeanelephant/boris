### Docs

- Remove standing-doc drift: [`STATUS.md`](/docs/STATUS.md) drops its stale "through PR #N" line, [`RELEASE-GATE.md`](/docs/RELEASE-GATE.md) points to `ci.yml` for CI coverage and no longer lists the shipped `boris watch --serve` as deferred, and the header of [`check-pr-issue-close.sh`](/scripts/check-pr-issue-close.sh) is now the single statement of the issue-close rules, with the [PR template](/.github/PULL_REQUEST_TEMPLATE.md) pointing to its local `--body-file` check.
