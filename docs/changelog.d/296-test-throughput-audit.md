### Docs

- Recorded a [test-throughput audit](/docs/archived/audits/test-throughput-audit.md): the `zig build test` graph is already fully sibling-parallel; scaling `-j1`→`-j8` is ~3x and the residual wall-time floor is structural (~8.8x shared-suite re-execution across four co-dominant test roots), so no build-graph change was made.