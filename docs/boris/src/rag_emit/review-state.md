---
title: "`src/rag_emit.zig` review state"
id: docs/boris/src/rag_emit/review-state
parent: docs/boris/src/rag_emit
status: draft
tags: [boris, zig, source-reference, review-state, rag_emit]
---

# `src/rag_emit.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following items are observations about gaps or future-proofing considerations. They are not defects in the current implementation.

1. **No unit tests for H1 normalization helpers.** `stripLeadingAtxH1` and `demoteAtxH1ToH2` are private helpers whose correctness is load-bearing for the RAG corpus structure. Adding direct unit tests for edge cases (lone `#`, indented H1, CRLF body, empty body, H1-only body) would strengthen the evidence base without changing production behavior.
2. **No unit tests for `renderContentDocument` or `renderRelations` edge ordering.** The sort in `renderRelations` is structurally enforced, but the hub-section order depends on the caller providing a freeze-sorted slice. A test with an out-of-order input would verify the dependency.
3. **`scratch` allocator constraint is implicit.** `renderContentDocument` allocates intermediates from `scratch` without individually freeing them. A doc comment stating that `scratch` must be an arena (or that intermediates are intentionally leak-tolerant) would make the ownership model explicit.
4. **`upload_guide` is a compile-time string constant.** If its content ever needs to reference a runtime version, it will need to become a render function. Currently it is not parameterized.
5. **`renderCatalogMeta` produces a single-line JSON string.** The schema version is a `u32` and is formatted with `{d}`. If the schema version ever reaches a value that requires more than the current formatting assumption, this is safe due to `std.fmt.allocPrint`'s dynamic sizing—no issue exists, but the function has no test.
