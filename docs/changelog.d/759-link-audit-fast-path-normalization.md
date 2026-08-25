<!--
Filename: 759-link-audit-fast-path-normalization.md
-->

### Changed

- Large HTML builds audit links up to ~10× faster: the output link audit's
  route resolution now normalizes dot-segment, query-suffixed, and
  root-relative references in caller-owned scratch instead of allocating per
  reference, and its resolution buffer is reused per document rather than
  re-poisoned per reference; published bytes are unchanged.
  [timings counters](/docs/contracts/cli.md), issue #759.
