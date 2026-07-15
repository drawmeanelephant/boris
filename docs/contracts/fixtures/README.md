# Contract and release-gate fixtures

This tree owns focused compiler contract fixtures. The existing `valid/` and
invalid suites are exercised by `scripts/release-gate.sh`.

Feature 8 adds a contracts-first skeleton under
`graph-native-dependencies/`. Its `edge-skeleton.json` pins the IR 0.2 edge and
reverse-index semantics before the compiler emits them; F8.2 will promote it to
a complete generated `graph.json` golden and wire it into the release gate.

The repository-root [`../../../fixtures/`](../../../fixtures/) remains the
milestone-2 inventory corpus checked by `src/fixtures_test.zig`.

Normative contracts: [../README.md](../README.md).
