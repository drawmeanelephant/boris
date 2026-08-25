### Fixed

- Semantic-relation target validation now reuses one page-identity index per graph
  pass, keeping relation-heavy validation near-linear while preserving the
  existing diagnostics and ordering ([semantic-relations contract](/docs/contracts/semantic-relations.md)).
