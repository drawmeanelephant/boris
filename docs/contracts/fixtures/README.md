# Contract and release-gate fixtures

This tree owns focused compiler contract fixtures. The existing `valid/` and
invalid suites are exercised by `scripts/release-gate.sh`.

Feature 8 is shipped under `graph-native-dependencies/`. Its full generated
`graph.json` golden pins the IR 0.2 typed-edge and reverse-index semantics and is
enforced by the release gate; `edge-skeleton.json` remains the compact contract
pin for the same sorted arrays. F8.3 dirty-set consumption is still pending.

The repository-root [`../../../fixtures/`](../../../fixtures/) remains the
milestone-2 inventory corpus checked by `src/fixtures_test.zig`.

Normative contracts: [../README.md](../README.md).
