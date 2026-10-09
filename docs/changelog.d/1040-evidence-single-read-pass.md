### Fixed

- `boris build`, `boris watch`, and `boris init` no longer hang at the end of
  compile on Windows: the [publication-claims](/docs/contracts/publication-claims.md)
  evidence chain now reads each committed report once and replays the collected
  bytes to the parser from memory, removing the rewind-and-reread pass that
  never completed on asynchronous no-follow file handles under Zig 0.17
  ([#1032](https://github.com/drawmeanelephant/boris/issues/1032)). The
  transient buffer is bounded at 64 MiB per report; a larger committed report
  is rejected as malformed rather than allocated.
