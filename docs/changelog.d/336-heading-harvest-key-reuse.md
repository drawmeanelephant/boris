### Changed

- Heading-harvest cache keys now reuse the already-computed per-page
  fingerprints instead of re-hashing full source/include bytes, and the
  heading index is built after the fingerprint pass (with fragment
  validation deferred to that point); the side-cache format is bumped to
  `boris-heading-harvest-v2` (one intentional harvest invalidation)
  ([heading ids contract](/docs/contracts/heading-ids.md)).
