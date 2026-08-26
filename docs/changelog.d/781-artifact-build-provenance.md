<!--
Filename: 781-artifact-build-provenance.md
Keep exactly one category heading.
-->

### Added

- Build provenance (#781) now records the binary's baked VCS revision token in three output surfaces — complete-mode RAG `catalog_meta.json` (`vcs_revision`), `boris recipe-scale` view envelopes (`vcsRevision`), and the publication Proof Pack pair (`vcs_revision` after `target`, mirrored in `_boris/proof/index.html`) — each additive with the `""` sentinel when undetected, so every upstream evidence digest stays deterministic for the same content; the IR artifact set deliberately keeps no provenance field (decision recorded in [cli.md](/docs/contracts/cli.md) and [ir-schema.md](/docs/contracts/ir-schema.md)). Links: [rag-export](/docs/contracts/rag-export.md), [cooklang-compatibility](/docs/contracts/cooklang-compatibility.md), [publication-proof-pack](/docs/contracts/publication-proof-pack.md), [#781](https://github.com/drawmeanelephant/boris/issues/781).
