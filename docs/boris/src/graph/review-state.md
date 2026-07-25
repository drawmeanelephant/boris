---
title: "`src/graph.zig` review state"
id: docs/boris/src/graph/review-state
parent: docs/boris/src/graph
status: draft
tags: [boris, zig, source-reference, review-state, graph, validation]
---

# `src/graph.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following items are observations about gaps, not defects; they are recorded here for planning purposes only.

- **Test the `EPARENTSELF` + satellite-of-satellite interaction**: add a fixture with a self-referential node that is also named as a parent by another node, and assert whether `EPARENTNOTTRUNK` is expected or suppressed.
- **Test `buildBreadcrumb` defensive guard**: create a scenario (post-freeze, manually injected residual cycle) to confirm the guard fires and document what the caller receives.
- **Test `diagnoseDuplicateIds` with three or more duplicates**: the current test only covers exactly two duplicates. The "first wins" claim for three entries with the same ID is untested.
- **Consider documenting the `retain` allocator lifetime requirement more explicitly**: the module-level doc comment does not state that `retain`-owned strings inside diagnostics must outlive the `diags` list. This is implied by the two-allocator pattern but not stated.
- **Consider a hard assertion or error return in `buildNav` when `frozen` is false**: currently, `buildNav` accepts any `[]const Node` without checking `frozen`. Calling it before freeze produces silently incorrect navigation.
