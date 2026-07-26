### Changed

- Incremental HTML builds no longer expand the dirty set with nested linear
  scans. `cache.NodeLookup` indexes entity ids and source paths once, and
  `expandDirtySet` resolves affected pages through hash lookups instead of
  scanning every page per affected id. Behaviour is unchanged; the previous
  path was quadratic in page count on builds where many pages are dirty.
  Measured ~5% faster on a cold 5k- and 10k-page incremental build.
