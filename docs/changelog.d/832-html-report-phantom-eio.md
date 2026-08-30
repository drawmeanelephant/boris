### Fixed

- HTML `build`/`validate --report` no longer mangles content failures with a
  phantom `EIO` fallback diagnostic: parse failures now reach the report with
  their real code, source path, and position, and the generic fallback is
  skipped whenever the report already holds a structured error, so
  `errorCount` reflects the actual failure count instead of being inflated on
  graph or layout failures. A genuine I/O failure with no structured
  diagnostic still yields the `EIO` explanation. Links:
  [the diagnostics contract](/docs/contracts/diagnostics.md),
  [#829](https://github.com/drawmeanelephant/boris/issues/829).
