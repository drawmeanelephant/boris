---
title: "`src/dependency.zig` review state"
id: docs/boris/src/dependency/review-state
parent: docs/boris/src/dependency
status: draft
tags: [boris, zig, source-reference, review-state, dependency]
---

# `src/dependency.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Identified gaps and potential follow-up work

The following items are observations about what the current tests and code do not cover. They are offered as documentation of known gaps, not as defect reports or prescriptive change requests.

**Test coverage gaps:**

- No test exercises the deduplication guard. Adding the same `(source, target, kind)` triple twice and verifying the output contains exactly one entry would close this gap.
- No test verifies sort order of keys or dependencies in the emitted JSON.
- No test checks the actual structure of `"forward"` and `"reverse"` values — only their presence as substrings.
- No test exercises paths with JSON-sensitive characters (`"`, `\`, newlines).
- No test exercises self-loop edges (source == target).

**Design observations:**

- The `schemaVersion` string `"0.1.0"` embedded in `renderJson` differs from the IR `schemaVersion` `"0.2.0"` documented in `docs/STATUS.md`. Whether this is intentional (separate versioning namespace for the dependency sub-schema) or a stale constant is uncertain from this file alone.
- `addDependency` has a partial-update hazard: a forward insert that succeeds before a reverse allocation failure leaves the index in an inconsistent state. This is not a defect under normal allocator operation but could manifest under injection testing or OOM simulation.
- Key slices (`source` and `target`) are stored by reference without copying. The caller contract for lifetime is not documented in the file.
- `renderJson` mutates the internal lists' item order as a side effect of sorting during serialization. This is not documented.
- The `gpa` parameter to `renderJson` is independent from `self.allocator`, which is a valid design but may surprise callers who expect a single allocator to own all memory associated with the index.
