---
title: "`src/apex_hostile_test.zig` review state"
id: docs/boris/src/apex_hostile_test/review-state
parent: docs/boris/src/apex_hostile_test
status: draft
tags: [boris, zig, source-reference, review-state, apex_hostile_test]
---

# `src/apex_hostile_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and limitations not addressed by this file

1. **Allocator `free` callback under hostile conditions.** The double does not call `allocator->free` on any path. Whether `zigFree` correctly survives a hostile engine that calls it with garbage pointers or calls it with valid arena pointers (attempting a double-free) is untested here. Covered only indirectly by large-render tests in the real engine suite.
2. **Post-return callback hostility.** An engine that retains the `ApexAllocator` struct pointer and invokes `alloc` or `free` after `apex_render` returns — use-after-stack or use-after-free — is not simulated. This is acknowledged in `remainingAbiAssumptions` as a vendor contract that Zig cannot enforce.
3. **Concurrency under hostile conditions.** The `render_mutex` path is not exercised by these tests. Concurrent hostile calls (two threads simultaneously triggering `@HOSTILE_OOM`) are not tested.
4. **Integer width edge cases.** `out_len = SIZE_MAX` or `out_len` values near `usize` overflow boundaries are not tested. The comptime width check catches mismatched `size_t`/`usize` at compile time, but does not prevent hostile large-value injection at runtime.
5. **C double vs. real engine divergence.** The hostile double pre-zeros outputs before dirtying them on error, matching the documented "pre-zero on entry" rule from `apex-abi.md`. This is actually *more* compliant than a purely adversarial engine; a truly hostile double that never pre-zeros might expose different wrapper behavior, though the status-first gate makes this irrelevant for correctness.
6. **Partial allocator success before OOM.** The double either fully succeeds or immediately returns OOM without having allocated anything. A real OOM scenario where several partial allocations succeed before the engine fails and returns `APEX_ERR_OOM` (leaving partially initialized output) is not simulated.

***

## Potential follow-up work

- Add a hostile case that calls `allocator->free` with a garbage pointer or with a previously `alloc`-returned pointer to test `zigFree`'s no-op behavior under adversarial conditions.
- Add a hostile case returning `out_len = SIZE_MAX` on success with a non-null pointer to verify no integer overflow in slice construction.
- Extend the double with a `@HOSTILE_POST_RETURN` mode that stores the allocator pointer in a global and allows a follow-on test to trigger a post-return callback, exercising the use-after-stack hazard explicitly.
- Consider a property-based or seed-driven fuzz pass over `mapRenderResult` covering the full `c_int` range of status values and the cross-product of null/non-null pointer with zero/nonzero length.
