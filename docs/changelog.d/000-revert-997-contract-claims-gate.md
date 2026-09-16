<!--
Filename: 000-revert-997-contract-claims-gate.md
-->

### Changed

- Removed the contract-claim registry gate added in [#997](https://github.com/drawmeanelephant/boris/pull/997). Quoted-tether records and the `--audit` worklist were extra process on top of existing unit, CLI, and release-gate checks; they made `zig build test` slower without changing compiler behavior. The Cooklang `{`-adjacency defect stays open. Links: [the test harness](/test/README.md), [#907](https://github.com/drawmeanelephant/boris/issues/907).
