# Contract and release-gate fixtures

This tree owns focused compiler contract fixtures. The existing `valid/` and
invalid suites are exercised by `scripts/release-gate.sh`.

Feature 8 is shipped under `graph-native-dependencies/`. Its full generated
`graph.json` golden pins the IR 0.2 typed-edge and reverse-index semantics and is
enforced by the release gate; `edge-skeleton.json` remains the compact contract
pin for the same sorted arrays.

Feature 9 (heading-target wiki links) lives under:

| Fixture | Role |
|---------|------|
| `wiki-heading-fragments/` | Success-shape author examples (`[[id#heading]]`) |
| `wiki-heading-missing/` | Missing fragment must fail HTML with `EREFERENCEMISSING` |

HTML integration coverage is in `src/compile.zig` / `src/wikilink.zig`; the
release gate smokes the missing-fragment fixture for exit **1**. Fragment
existence is validated on the **HTML** path only (requires Apex-rendered ids);
IR still projects page→page `reference` edges without heading membership checks.

The repository-root [`../../../fixtures/`](../../../fixtures/) remains the
milestone-2 inventory corpus checked by `src/fixtures_test.zig`.

Normative contracts: [../README.md](../README.md),
[../heading-ids.md](../heading-ids.md).
