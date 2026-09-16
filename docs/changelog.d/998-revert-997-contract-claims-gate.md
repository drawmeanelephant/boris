<!--
Filename: 998-revert-997-contract-claims-gate.md
-->

### Changed

- Removed the contract-claim registry gate added in [#997](https://github.com/drawmeanelephant/boris/pull/997), and forbade standing up a replacement. Quoted-tether records and the `--audit` worklist were extra process on top of existing unit, CLI, and release-gate checks; they made `zig build test` slower without changing compiler behavior. [`AGENTS.md`](/AGENTS.md) now treats parallel verification products (claim registries, quote-tethers, contract-audit worklists, `known-divergence` ratchets) as needing an explicit user request; a contract the code does not honor is a defect to fix or rewrite, not a new gate. The Cooklang `{`-adjacency defect stays open. Links: [the test harness](/test/README.md), [the agent playbook](/docs/AGENT-PLAYBOOK.md), [#907](https://github.com/drawmeanelephant/boris/issues/907).
