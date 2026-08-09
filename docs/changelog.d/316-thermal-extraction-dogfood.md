### Fixed

- Boris check now reports unreferenced_page findings without failing by
  default, with an explicit --fail-on-unreferenced opt-in for CI; HTML
  publication also rejects literal local Markdown routes that are absent from
  the intended output manifest. See the
  [CLI contract](/docs/contracts/cli.md), [Documentation Intelligence contract](/docs/contracts/documentation-intelligence.md),
  and [documentation-link contract](/docs/contracts/documentation-links.md).
