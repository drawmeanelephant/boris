---
title: "`src/incremental_scale_smoke_test.zig` review state"
id: docs/boris/src/incremental_scale_smoke_test/review-state
parent: docs/boris/src/incremental_scale_smoke_test
status: draft
tags: [boris, zig, source-reference, review-state, incremental_scale_smoke_test]
---

# `src/incremental_scale_smoke_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

> The following are observations about possible gaps, not defects. No repository file has been modified.

- The byte-identity comparison skips `.boris-cache/`. A future test could assert that the heading-harvest and manifest cache files are also structurally identical across sequential and parallel runs to strengthen the determinism guarantee for the full dist tree.
- Only the post-edit state is compared for byte-identity. Adding an explicit comparison of the cold-build parallel output against the cold-build sequential output would close a small logical gap.
- The dirty-set check asserts the cohort count (10 pages) but does not enumerate *which* 10 pages were written. A future assertion using `CompileStats` extended to report per-page results, or by checking file modification timestamps, could make the boundary more precise.
- The `edited_cohort_count` includes the full Satellite cohort of the edited Trunk, not just the directly edited Satellite and its wikilinked parent. This is described as "conservative" in the README. When the dirty-set algorithm is narrowed, the expected count in this test must be updated.
