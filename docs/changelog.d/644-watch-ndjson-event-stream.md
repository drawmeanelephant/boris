<!--
Filename: 644-watch-ndjson-event-stream.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Added

- `boris watch --watch-json` now emits a machine-readable event stream: one
  NDJSON object per line on stderr (`hello` version handshake, `build-started`,
  `build-succeeded`, `build-failed` with structured diagnostics, `watcher-started`,
  `serve-started`, `watch-error`, `watch-stopped`). The stream is exclusively
  NDJSON — compile progress and prose diagnostics are suppressed for the
  lifetime of each build — and `--quiet` is implied for the compile path while
  exit codes stay unchanged. The single-target watch recovery set now matches
  the multi-target path (all author-correctable content failures, including
  broken wiki-links and link-audit failures, keep the watcher alive instead of
  exiting). Pinned end-to-end by `zig build test-watch-json-contract` and
  documented in the [watch-mode contract](/docs/contracts/watch-mode.md).
