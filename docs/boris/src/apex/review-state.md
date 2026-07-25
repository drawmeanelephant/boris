---
title: "`src/apex.zig` review state"
id: docs/boris/src/apex/review-state
parent: docs/boris/src/apex
status: draft
tags: [boris, zig, source-reference, review-state, apex]
---

# `src/apex.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and limitations

1. **Release-mode watermark absent.** The arena capacity watermark that detects libc `free` violations during the C call only fires in `Debug` builds. In `ReleaseSafe` and `ReleaseFast` builds, a production C engine that calls libc `free` on arena bytes would corrupt the arena silently. The ASAN step (`zig build test-apex-sanitize`) is the complementary check, but it is opt-in and may skip.
2. **`mapRenderResult` is only safe if it is the sole post-call gate.** The function is `pub`, which enables hostile tests to call it independently. But it also means a future caller could, in principle, skip it and read `out_ptr` directly after a failed `c.apex_render`. The design depends on `render` being the only production call site of `c.apex_render`.
3. **`zigAlloc` zero-size semantic.** The ArenaAllocator may legally return a zero-length slice with a valid (but architecturally null-adjacent) base pointer for a zero-size allocation. The function guards `if (@intFromPtr(slice.ptr) == 0) return null` for this, but whether this guard is reachable depends on the allocator implementation. Under the current `ArenaAllocator`, a zero-size alloc returns a non-null `ptr` in practice (slices carry a length separate from the pointer), but this is not contractually guaranteed by `std.mem.Allocator`.
4. **`Html` carries no arena reference.** Nothing prevents a caller from keeping an `Html` value past the arena's `reset(.free_all)` or `deinit()`. The `owns_memory = false` and doc-comments document the expectation, but no Zig type-level enforcement exists for cross-reset slice validity.
5. **`version()` returns a `[]const u8` via `std.mem.span` on `apex_version()`'s static C string.** The slice is valid for the process lifetime per the header (`"static storage; never freed"`). No copy is made. This is safe under the stated ABI but creates a dependency on the C symbol's storage class, which Zig cannot verify.
6. **U18 D4 smoke uses `std.heap.page_allocator` for worker arenas.** The test comment explains that `std.testing.allocator` is not thread-safe. `page_allocator` is, but failure inside `Worker.run` is communicated only via a shared `std.atomic.Value(bool)`. Diagnostic information for a failure (which sample, which round, which expected vs. actual bytes) is not captured; only the failure flag is set. An investigator must re-run sequentially to reproduce.
7. **Fidelity goldens are version-pinned.** The `fidelityEqualGolden` tests for U1 (GFM table), U7 (footnote), U9 (math), and U10 (callout) pin exact HTML strings to ApexMarkdown v1.1.12 Unified. An engine version upgrade that changes attribute order, whitespace, or element shape will fail these tests. This is intentional but requires deliberate golden updates on any engine pin change.

***

## Potential follow-up work

- Add a `comptime` or runtime assert that `render` is the only call site of `c.apex_render` within the module, or document the invariant in a comment at the `c.apex_render` call site to prevent future additions that bypass `mapRenderResult`.
- Consider exposing the arena-shrinkage watermark in `ReleaseSafe` builds with a conditional compile check, accepting the minor overhead in exchange for earlier detection of production `free`-on-arena violations.
- The `std.math.add(usize, n, 0) catch return null` idiom in `zigAlloc` would be clearer with an inline comment explaining that this is an intentionally identity-safe placeholder for a future non-trivial arithmetic step.
- U18's `Worker.run` could capture the first failing sample index and expected/actual byte counts into pre-allocated worker-local buffers for post-join diagnostic output.
- The fidelity golden update procedure (which goldens to update, which `fidelityEqualGolden` calls to re-baseline, what commands to run) would benefit from a short section in `docs/contracts/apex-abi.md`.
