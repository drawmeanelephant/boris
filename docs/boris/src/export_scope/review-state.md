---
title: "`src/export_scope.zig` review state"
id: docs/boris/src/export_scope/review-state
parent: docs/boris/src/export_scope
status: draft
tags: [boris, zig, source-reference, review-state, export_scope]
---

# `src/export_scope.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following observations are not defects but represent gaps that a subsequent work card could address.

1. **Explicit test for transitive-closure termination.** The current tests do not include a fixture where the semantic neighbor's parent is not also an ancestor of the seeded page, verifying that the parent closure correctly reaches indirect ancestors of relation-expanded pages. A fixture with depth ≥ 3 would strengthen this.
2. **Test for scope with exactly one trailing `/`.** The current scope validation rejects any scope containing `/`, which means a scope ending in `/` is rejected. This is the correct behavior for preventing ambiguous collection selectors, but it is not explicitly tested.
3. **Fence-close length test.** No test exercises a closing fence whose length exceeds the opening fence length (e.g., open with ```````````, close with ```` ```` ````). Adding such a test would confirm the `>=` close condition.
4. **Minimality note in docs.** The greedy partition strategy should be documented as greedy (not minimal) in the function's doc comment, so callers that care about part count are not surprised.
5. **Cycle guard.** If a defensive upper-bound iteration limit were added to the Phase 3 parent-closure loop, it would protect against a malformed input reaching this function outside the normal pipeline validation path (e.g., in a future test double). This is a hardening suggestion, not a current defect.
