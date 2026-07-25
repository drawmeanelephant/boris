---
title: "`src/fixtures_test.zig` review state"
id: docs/boris/src/fixtures_test/review-state
parent: docs/boris/src/fixtures_test
status: draft
tags: [boris, zig, source-reference, review-state, fixtures_test]
---

# `src/fixtures_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

1. **Wire length of `valid` to manifest rather than magic `4`**
Or assert `valid.len >= 1` and full path coverage without freezing count, if the valid suite is expected to grow.
2. **Assert bijection**
Every `required_categories` code appears exactly once as an `expectedCategory` (currently ⊆ checks allow duplicates).
3. **Optional: reject unknown categories**
Seen categories that are not in `required_categories` could be warnings/failures to prevent inventing codes only in the root inventory.
4. **Build-system cwd note**
Document in `docs/RELEASE-GATE.md` / test README that this module requires package-root cwd (already logged on open failure).
5. **Do not expand this file into a second compiler harness**
Per module header and milestone split, compiler validation belongs under contract fixtures and hardening tests—not here.[^3_1]
