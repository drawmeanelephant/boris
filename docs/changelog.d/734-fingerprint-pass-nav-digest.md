### Changed

- The incremental fingerprint pass builds its wiki node map once per build and
  folds a fixed-size digest of the site nav material into each page
  fingerprint, making large graph-chrome builds measurably faster. Fingerprint
  composition changes with cache format `boris-cache-v3-nav-digest`; older
  caches force the documented one-time cold rebuild. See
  [html-output](/docs/contracts/html-output.md) and
  [#727](https://github.com/drawmeanelephant/boris/issues/727).
