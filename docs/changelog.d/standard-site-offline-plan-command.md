### Added

- Added `boris standard-site plan --profile PATH [--out PATH]`, a pure-offline
  command that renders the deterministic Standard.site plan (publication +
  document records, `textContent` digests, exclusions, verification surfaces)
  to stdout or a file with no network authority. It shares the compile and
  projection pipeline with `publish`, so the emitted bytes match the plan
  `publish --plan` validates. See the
  [Standard.site target contract](/docs/contracts/standard-site.md).
