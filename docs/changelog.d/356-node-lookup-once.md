### Changed

- Wiki-link materialization now resolves entities by binary search over the
  id-sorted frozen node array instead of rebuilding a node map per page,
  making the fingerprint phase linear in page count without changing any
  reference-material or fingerprint bytes
  ([incremental freshness contract](/docs/contracts/html-output.md)).
