<!--
Filename: 795-source-rag-vcs-revision.md
Keep exactly one category heading.
-->

### Added

- Standalone `boris-source-rag` corpus metadata now carries the bake-time VCS revision token (`catalog_meta.json` trailing `vcs_revision`, `""` sentinel when undetected; `256`-byte fixed buffer sized for the added field) threaded explicitly from the `build_info` compile-time plumbing rather than any runtime Git probe, mirroring [#794](https://github.com/drawmeanelephant/boris/pull/794)'s additive pattern without touching determinism semantics ([source-RAG guide](/tools/source-rag/README.md), [#795](https://github.com/drawmeanelephant/boris/issues/795)).
