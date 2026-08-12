### Changed

- Build-constant fingerprint inputs (site-nav material, layout bytes, theme
  material) are now hashed once per build and mixed into page fingerprints as
  fixed-size digests, removing the per-page re-hashing that grew with site
  size; the cache format is bumped to `boris-cache-v3-constant-digests`
  (one intentional cold rebuild)
  ([incremental freshness contract](/docs/contracts/html-output.md)).
