### Fixed

- Incremental page freshness now indexes prior cache-manifest entries once per
  build, replacing a linear manifest scan per page with expected O(1) lookups
  while preserving duplicate-entry first-match-wins semantics
  ([incremental freshness contract](/docs/contracts/html-output.md)).
