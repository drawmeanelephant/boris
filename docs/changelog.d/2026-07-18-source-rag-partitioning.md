### Added

- Added deterministic whole-file source-RAG bundle partitioning with
  `--split-size`, ordered `part_manifest.json` provenance, and documented
  oversized-file and `--no-bundles` behavior. On the v0.6.1 `origin/main`
  tree, the default all-profile export measured **10,408,617 bytes across 623
  files** before the change and **10,499,233 bytes across 632 files** after it;
  additive bundle bytes measured **5,055,471 → 5,070,111** across **4 → 12**
  parts. See the [source-RAG guide](/tools/source-rag/README.md).
