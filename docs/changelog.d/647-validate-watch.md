<!--
Filename: 647-validate-watch.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Added

- `boris validate --watch` starts a zero-write validation daemon (issue #647):
  the same debounced watch coordinator as HTML watch mode re-runs the
  `validate` preflight on every change and writes nothing — no target, cache,
  search, or evidence trees ever appear. `--watch-json` carries each cycle on
  the NDJSON event stream with `mode` `"validate"` and `pages_written` `null`,
  and `--report PATH` is replaced (never appended) every cycle. `--html-dir`,
  `--target`, `--serve`, and `--port` are usage errors with it; the daemon
  exits `0` on SIGINT/SIGTERM. Pinned by the extended
  `zig build test-watch-json-contract` and documented in the
  [watch-mode](/docs/contracts/watch-mode.md) and
  [validation](/docs/contracts/validation.md) contracts.
