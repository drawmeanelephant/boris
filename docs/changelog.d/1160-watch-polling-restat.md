### Changed

- Reuse tracked file snapshots and traversal buffers across [watch mode](/docs/contracts/watch-mode.md) poll cycles (with bulk directory-attribute reads on macOS), eliminating steady-state heap allocations and per-file re-stat churn on unchanged trees while preserving in-place edit detection and transient root-error recovery.
