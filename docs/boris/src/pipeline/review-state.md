---
title: "`src/pipeline.zig` review state"
id: docs/boris/src/pipeline/review-state
parent: docs/boris/src/pipeline
status: draft
tags: [boris, zig, source-reference, review-state, pipeline, compiler]
---

# `src/pipeline.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following observations arise from inspecting the file but are not defects in the current implementation. They are candidates for future work:

1. **`validateSemanticRelations` diagnostic line numbers are always `1, 1`.** The frontmatter parser returns byte-offset-based line numbers for other categories. Semantic relation fields could be similarly located during parsing to improve diagnostic precision.
2. **`validateSemanticRelations` uses an O(n²) duplicate scan** over per-node relations. For typical content trees this is not a performance concern, but a set-based approach would scale better for nodes with many semantic relations.
3. **`layout_path` is hardcoded `null` in the `compile` → `graph_mod.freeze` call.** The comment notes "TODO: wire layout_path when CompileOptions gains one." This is acknowledged technical debt.
4. **`publishArtifacts` uses per-file rename, not directory rename.** The policy comment documents this limitation. A directory-level atomic swap would make the publication step more robust for concurrent readers, but the current policy is explicitly documented as not claiming cross-platform atomic guarantees.
5. **`hasCode` is defined but unused in tests.** This is a minor dead-code item.
6. **`populateDependencyIndex` and `populateDependencyIndexFormat` duplicate some logic from `resolveDependencies`.** The duplication is structurally intentional (different callers, different error surfaces), but the shared core (scan-wiki + scan-includes + body-offset validation + Textile adaptation) could be extracted into a lower-level helper if divergence becomes a maintenance risk.
