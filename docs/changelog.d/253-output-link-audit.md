### Added

- Published local `href`/`src` references are now audited against the outputs a
  build intends to keep, immediately before the staged tree is committed, so a
  reference that climbs above the output root or names nothing publishable fails
  the build with `EROUTEESCAPE` / `EROUTEMISSING` and leaves the published tree
  untouched. Links:
  [the diagnostics contract](/docs/contracts/diagnostics.md).
