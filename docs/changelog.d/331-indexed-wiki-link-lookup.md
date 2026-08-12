### Changed

- PERF-013 (issue #331): wiki-link target resolution and semantic-relation
  validation now use a page-id index built once per resolution pass instead of
  scanning every page per hit, removing the O(links × pages) scaling cliff on
  large corpora while keeping first-wins behavior, missing-link diagnostics,
  and diagnostic ordering unchanged. The deterministic benchmark corpus
  generator gained a `--dense-links` mode for measuring dense corpora with
  [the benchmark harness](/tools/testdata-generator/README.md).
