### Added

- `boris watch --serve` now surfaces rebuild failures in the preview: a new
  `GET /__boris/status` endpoint reports
  `{state, stale_reason, last_error, last_build_ms}`, the SSE stream emits
  `stale` instead of `reload` after a failed cycle, and served HTML pages
  carry an injected `__boris-stale` banner naming the first error diagnostic
  until the next successful build clears it. Links:
  [cli.md](/docs/contracts/cli.md),
  [watch-mode.md](/docs/contracts/watch-mode.md).
