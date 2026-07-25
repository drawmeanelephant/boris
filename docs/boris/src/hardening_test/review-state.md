---
title: "`src/hardening_test.zig` review state"
id: docs/boris/src/hardening_test/review-state
parent: docs/boris/src/hardening_test
status: draft
tags: [boris, zig, source-reference, review-state, testing, integration]
---

# `src/hardening_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

- **Cross-platform determinism validation.** The dual-run tests prove byte identity on a single host within one session. A CI matrix running on Linux and macOS could extend coverage to file-system differences in `readdir` behavior. This is a test infrastructure change, not a code change.
- **Diagnostic message content assertions.** The duplicate-ID test checks that the message contains `"alpha"` or `"beta"` but uses `||` (either-or), not `&&`. If the implementation emits a message mentioning only one path, the test passes. A stricter assertion would check that both paths appear.
- **Mixed-error fixtures.** No fixture tree currently combines two distinct error categories (e.g., a duplicate ID and a cycle in the same tree). Adding such fixtures would verify that both codes appear in the diagnostic set and that neither suppresses the other.
- **RAG `:::details` attribute ordering.** The RAG Details test uses `expectEqualStrings` against an exact attribute string. If attribute order is not canonicalized, this test would be fragile against implementation changes that reorder attributes. A contract note or normalization step would reduce brittleness.
- **Empty and edge-case `codesSet` behavior.** `codesSet` is called only on diagnostic lists that are known non-empty. A zero-diagnostic list (e.g., after a successful run) is never passed to `codesSet`; behavior in that case is not exercised.
- **`build-report.json` exclusion rationale.** The dual-run tests explicitly exclude `build-report.json` from byte comparison with the comment "embeds outDir so is excluded." If the build-report schema is extended with other potentially non-deterministic fields (e.g., wall-clock timing), that exclusion would need to be re-documented.
