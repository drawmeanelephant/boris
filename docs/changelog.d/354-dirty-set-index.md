### Fixed

- Incremental dirty-set expansion now resolves affected page ids and frozen
  node keys through once-per-build maps instead of per-id linear scans of the
  page/nodes arrays, removing the O(n²)–O(n³) dirty-propagation cliff on
  dense reference corpora without changing which pages are rebuilt
  ([incremental freshness contract](/docs/contracts/html-output.md)).
