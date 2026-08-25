<!-- 773-include-read-memoization.md -->

### Changed

- `{{include}}` fragments are read and expanded once per build and shared
  across consuming pages instead of once per page, cutting duplicate file
  reads on sites with shared chrome fragments (#760). The `--timings`
  `include_reads` counter now reports unique fragment reads per build.
