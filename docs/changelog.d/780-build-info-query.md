<!-- Filename: 780-build-info-query.md -->

### Added

- Added the additive `boris --build-info` provenance query: one JSON line on
  stdout pairing the base compiler id with the VCS revision baked in at build
  time (`-Dvcs-revision` override; `.dirty` suffix; empty without git), so two
  builds of the same version are distinguishable without touching
  `--version`, exit codes, or artifact schemas. The HTML-path
  [`--report`](/docs/contracts/diagnostics.md) document mirrors the token as
  its additive `vcsRevision` field. See
  [the CLI contract](/docs/contracts/cli.md).
