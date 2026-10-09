### Fixed

- Frontmatter-sourced graph diagnostics now point at the offending field line
  instead of `1:1`: `EPARENTMISSING`, `EPARENTSELF`, and each `EPARENTCYCLE`
  participant report the page's `parent:` line, and `ERELATIONMISSING`,
  `ERELATIONSELF`, and `ERELATIONDUPLICATE` report the `relations:` line.
  Diagnostic `remediation` now carries a concrete action at every emit site
  where one exists (including parser failures, which previously fell back to a
  generic hint), and machine-readable reports no longer contain the circular
  "See the stderr diagnostic" pointer — see the
  [diagnostics contract](/docs/contracts/diagnostics.md) (#1021).
