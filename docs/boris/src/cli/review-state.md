---
title: "`src/cli.zig` review state"
id: docs/boris/src/cli/review-state
parent: docs/boris/src/cli
status: draft
tags: [boris, zig, source-reference, review-state, cli]
---

# `src/cli.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

- **`runArgs` allocator heuristic:** The `gpa` extraction via `@hasField` defaults to `std.testing.allocator` for runners without a `gpa` field. In production, a runner without this field would silently use the test allocator, which may panic or behave incorrectly outside tests. This is not validated by any test.
- **Conflict matrix completeness:** The conflict matrix is tested exhaustively for known pairs, but there is no mechanical enforcement that every new flag added to the parser has a corresponding conflict entry. A new flag added without updating the conflict matrix would pass parsing without error even if its combination with an existing flag is semantically invalid.
- **`--layout-rule` duplicate detection differs from `saw_*` pattern:** Duplicate `--layout-rule` entries for different targets are not caught by the scan loop. They are caught post-scan per-target via `rejectDuplicateSelectors`. A rule for an unknown target is also caught post-scan. These two layers of detection are correct but asymmetric with the rest of the parser.
- **`takeValue` not tested for all value flags:** Missing-value and empty-value coverage is confirmed for the most common flags. Whether `--context-dir`, `--report`, `--html-layout` (inline empty), `--target-layout` (inline empty), and `--theme` (empty) all produce the expected errors from `takeValue` is not directly demonstrated for every variant.
- **String lifetime not type-enforced:** `Options` fields that are views into argv carry no lifetime annotation. A caller that frees argv before calling pipeline code would produce dangling pointers. This is a language-level limitation in Zig v0.x, not a defect in the implementation, but it is a contract that callers must honor manually.
