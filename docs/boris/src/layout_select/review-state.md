---
title: "`src/layout_select.zig` review state"
id: docs/boris/src/layout_select/review-state
parent: docs/boris/src/layout_select
status: draft
tags: [boris, zig, source-reference, review-state, layout_select]
---

# `src/layout_select.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and unverified claims

- `max_rules_per_target` (256) triggering `error.RuleLimitExceeded` is declared and guarded in `rejectDuplicateSelectors` but no test in the inspected files directly exercises the 257-rule boundary. **Contract-only.**
- `globMatches` returns `false` for an empty `e_seg` mid-path (the `if (e_seg.len == 0) return false` guard). An entity id with a trailing or doubled `/` that passed validation would never reach `globMatches`, since `validateGlobPattern` and `identity.validateEntityId` both reject such forms. The guard is therefore defense-in-depth; whether it is reachable in practice is **uncertain**.
- `sortRulesCanonical` is documented as for "digests/diagnostics only — never as match precedence." This claim is supported by the code (sort is only called inside `ruleTableDigestMaterial`, not inside `selectLayout`). **Structurally checked.**
- The `docs/designs/page-layout-selection-rfc.md` and `docs/contracts/templating-and-themes.md §4` documents referenced in the module docstring were not inspected. Claims about their content are **uncertain**.
- The exact `build.zig` declaration for the `test-layout-hostile` step was not inspected. The step name is cited from the hostile test's own module docstring. **Contract-only.**
