### Added

- Added `--timings`, an opt-in machine-readable phase timing and counter report
  on stdout. It records scan/parse/graph/dependency durations on every mode and
  the full HTML publication pipeline (fingerprint, render, heading harvest,
  search, link audit, inventory, checks, claims, touches, proof pack) with
  page/include read, hash, link-resolution, and fast-path-hit counters. Default
  output, diagnostics, exit codes, artifacts, and `--quiet` are unchanged when
  the flag is absent. See the [CLI contract](/docs/contracts/cli.md).
