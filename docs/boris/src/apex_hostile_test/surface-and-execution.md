---
title: "`src/apex_hostile_test.zig` surface and execution"
id: docs/boris/src/apex_hostile_test/surface-and-execution
parent: docs/boris/src/apex_hostile_test
status: draft
tags: [boris, zig, source-reference, surface, apex_hostile_test]
---

# `src/apex_hostile_test.zig` surface and execution

## Threat model

The file addresses the following hostile behaviors, categorized by evidence:

### Non-zero status with dirty output parameters

The primary threat modeled. The C double, on all error paths, sets `*out_html` to a non-null garbage address (bit patterns `0xDEADBEEF`, `0xCAFEBABE`, `0xFEEDFACE`) and `*out_len` to a nonzero value (`0xBEEF`, `42`, `99`) *before* returning a non-zero status. A Zig wrapper that reads `out_html`/`out_len` before checking `rc` would attempt to form a slice from an unmapped address, causing a segfault or undefined behavior. Covered for `APEX_ERR_OOM`, `APEX_ERR_ARGS`, and the unknown-status (99) case.

### Success with ABI-violating null pointer and nonzero length

The `@HOSTILE_NULL_LEN` path returns `APEX_OK` (zero) while setting `*out_html = NULL` and `*out_len = 17`. This is an explicit ABI violation: success + null + nonzero length is not a valid combination under the documented contract (`apex-abi.md`). The wrapper must reject it rather than forming a slice `null[0..17]`, which is undefined behavior in Zig. Covered directly.

### Unknown or reserved non-zero status codes

The double returns `99` (not `APEX_ERR_ARGS` or `APEX_ERR_OOM`) with dirty outputs. The Zig wrapper maps any non-zero code that is not `APEX_ERR_OOM` to `error.RenderFailed`, without reading outputs. The `mapRenderResult` tests additionally check a reserved status value (`3`) to confirm it is treated as `RenderFailed` rather than being confused with `OutOfMemory`. Covered.

### Dirty output simulation via inline Zig mock

The `hostileApexRender` Zig function writes `{0xde, 0xad, 0xbe, 0xef}` into a stack buffer and sets `out_html` and `out_len` to point at it before returning `APEX_ERR_ARGS`. This tests `mapRenderResult` in isolation from C execution: the result must be `error.RenderFailed` and the poison values must not appear in any `Html.bytes`. A second variant uses `APEX_ERR_OOM` with a valid-looking `poison` buffer to confirm the OOM branch also ignores outputs.

### Allocator callback operation (benign path only)

The benign success case (`# hello\n` and empty input) calls through `apex_hostile.c`'s `host_alloc` helper, which invokes `allocator->alloc(allocator->ctx, size)`. This exercises `zigAlloc` and confirms it correctly allocates from the arena and returns a non-null pointer for the `plen`-byte `"<p>hostile-ok</p>"` output. The expected `Html.bytes` contains `"hostile-ok"`. The empty-input success path returns `NULL, 0` from the C double and must produce `Html{ .bytes = "" }` with `len == 0`.

**Untested categories within this file:**

- Allocator `free` callback (`zigFree`) with hostile-injected calls — not tested in the hostile binary (the double does not call `free` on success; zigFree is a no-op whose behavior is tested via large renders in the real-engine tests in `apex.zig`).
- Retained pointer hazard: a hostile engine that caches the arena pointer and calls `alloc`/`free` *after* `apex_render` returns — not simulated by the double.
- Concurrent hostile calls: `apex_hostile.c` uses only stack-local or static storage and does not exercise the `render_mutex` or race conditions.
- `ApexAllocator` struct layout mismatch (calling convention, field order): this is a comptime check in `apex.zig`, not a runtime hostile case.
- `md` pointer read beyond `md_len` (strlen usage by a hostile engine): not simulated.
- Integer overflow in `out_len` (e.g., `SIZE_MAX`): not tested.

***
