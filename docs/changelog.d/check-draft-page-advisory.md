### Added

- `boris check` now reports a `draft_page` advisory finding for each page whose
  frontmatter declares `status: draft` (leaving `published`, `archived`, and
  unset `status` unflagged), informational by default (exit 0) and promoted to
  exit 1 by the check-only `--fail-on-draft` flag without changing report bytes
  or schema `0.2.0`. See the
  [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md)
  and the [CLI contract](/docs/contracts/cli.md).
