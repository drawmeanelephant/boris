---
title: "`src/page.zig` review state"
id: docs/boris/src/page/review-state
parent: docs/boris/src/page
status: draft
tags: [boris, zig, source-reference, review-state, page]
---

# `src/page.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following observations are outside the scope of this dossier but are recorded for completeness. They are suggestions only; none represents a defect in the current implementation.

- **Mechanical freeze enforcement.** A `frozen: bool` field on `PageDb`, checked in `itemsMut()`, would catch out-of-order graph writes at runtime rather than relying on convention.
- **`FrontmatterView` lifetime tagging.** A comptime phantom lifetime parameter (or a wrapper struct that holds a reference to the source buffer sentinel) could make dangling-slice construction a compile error rather than a documentation contract. This is a significant ergonomic change and may not be warranted for the current codebase scale.
- **`promote` atomicity under partial failure.** If a multi-page batch fails mid-promote, the `PageDb` is in a partial state. The current API is single-call atomic (fail early, don't append), but there is no rollback mechanism for a session that has processed some pages successfully. Whether this matters depends on error-recovery strategy, which is not addressed in this file.
- **Bounds constants tested by the parser.** The constants declared here are the single source of truth per the module-level comment, but no test in `src/page.zig` itself verifies that `src/parser.zig` actually enforces them. Cross-referencing tests in `src/parser.zig` against the constants imported from this file would close that verification gap.
- **`RelationKind` test coverage.** The closed-vocabulary test covers `Status` but there is no corresponding test for `RelationKind.parse` in this file. The parser tests may cover this, but it is not tested here.
