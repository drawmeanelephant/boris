---
title: "`src/apex.zig` surface and execution"
id: docs/boris/src/apex/surface-and-execution
parent: docs/boris/src/apex
status: draft
tags: [boris, zig, source-reference, surface, apex]
---

# `src/apex.zig` surface and execution

## Module structure

The file divides naturally into six layers:

1. **Comptime ABI compatibility block** — `comptime { ... }` immediately after imports. Asserts five structural properties of the C ABI against the types produced by `@cImport` at build time.
2. **Public type and constant declarations** — `ApexError`, `Html`, `test_large_md_bytes`, `forbidApexFree`, `empty_md_sentinel`.
3. **Allocator callbacks** — `zigAlloc` and `zigFree`, both `callconv(.c)`.
4. **Rendering helpers** — `prepareMdForC` and `mapRenderResult`, both `pub` (callable from test code and the hostile suite).
5. **Engine serialization and primary `render` function** — `render_mutex`, `lockRenderMutex`, `unlockRenderMutex`, and `render`.
6. **ABI assumption registry and embedded tests** — `remainingAbiAssumptions`, `skipIfHostileEngine`, and all `test` blocks.

***

## Exported public surface

| Symbol | Kind | Purpose |
| :-- | :-- | :-- |
| `ApexError` | `error` set | `error.RenderFailed` and `error.OutOfMemory`; the only two errors `render` can return |
| `Html` | `struct` | Wraps `[]const u8`; `owns_memory = false` signals arena-borrowed lifetime |
| `Html.owns_memory` | `comptime bool` | Documentation invariant; tested directly |
| `test_large_md_bytes` | `pub const usize` | `64 * 1024`; bounds CI large-input test; exported for fuzz harness reuse |
| `forbidApexFree` | `pub fn(Html) noreturn` | Panic guard; must never be called on a live `Html`; defensive hook for future code paths |
| `prepareMdForC` | `pub fn` | Validates and converts `[]const u8` to `{ptr, len}` for C; handles empty-input sentinel |
| `mapRenderResult` | `pub fn` | Single post-`apex_render` status and output gate; `pub` for independent testing |
| `render` | `pub fn` | Full rendering entry point: lock, call C, unlock, gate, return `Html` or error |
| `version` | `pub fn` | Returns `apex_version()` as `[]const u8` via `std.mem.span` |
| `remainingAbiAssumptions` | `pub const [8][]const u8` | Audit list of vendor-contract assumptions Zig cannot enforce |

`zigAlloc` and `zigFree` are module-private (no `pub`). `render_mutex`, `lockRenderMutex`, and `unlockRenderMutex` are also module-private. `empty_md_sentinel` is `const` at file scope but not `pub`.

***

## Comptime ABI compatibility block

The `comptime` block executes at build time and triggers `@compileError` on any mismatch. It checks five properties:


| Check | What it detects |
| :-- | :-- |
| `@sizeOf(usize) != @sizeOf(md_len_t)` | `usize` / `size_t` width mismatch for the `md_len` parameter |
| `@sizeOf(usize) != @sizeOf(out_len_child)` | `usize` / `size_t` width mismatch for the `*out_len` parameter (pointer-to-`size_t`) |
| `render_info.params.len != 5` | `apex_render` arity change — ABI drift caught immediately |
| `c.APEX_OK != 0 or c.APEX_ERR_ARGS != 1 or c.APEX_ERR_OOM != 2` | Status constant values changed in the header |
| `alloc_info.fields.len != 3` | `ApexAllocator` field count changed |

**What the comptime block does not check:** calling conventions (assumed correct by `@cImport`), parameter types beyond widths (e.g., whether `md` is `const char *` vs `char *`), alignment of `ApexAllocator` fields, or whether `apex_free` and `apex_version` have compatible signatures. All five checks are purely structural; none prove behavioral contracts. The arity check is particularly valuable because a new `apex_render` parameter would silently compile under C but break Zig's `@cImport`-generated type if not caught here.

***

## Allocator callbacks

### `zigAlloc`

Signature: `fn(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque`

`ctx` is cast to `*std.mem.Allocator` using `@ptrCast(@alignCast(...))`. The function calls `allocator.alloc(u8, size)` on the arena, catches allocation errors, and returns null on failure. For the zero-size case, it explicitly does not return null — because null means OOM to the C engine. The comment notes: `size_t → usize width verified at comptime`, making the cast safe under the width assertions above.

The `std.math.add(usize, n, 0) catch return null` call is annotated as a "checked arithmetic placeholder for any future size padding/alignment." As written it is an identity that cannot overflow, but the pattern documents the intended safety point for future modifications.

**What this does not check:** the C engine calling `zigAlloc` concurrently from multiple threads, calling it after `apex_render` returns, or passing `ctx` that has been mutated between calls. These are vendor-contract assumptions (`remainingAbiAssumptions[0]` and `[5]`).

### `zigFree`

Signature: `fn(_: ?*anyopaque, _: ?*anyopaque, _: usize) callconv(.c) void`

Intentionally empty. All three parameters are discarded. The comment states: "arena bulk-free is the sole reclamation path. Safe to call any number of times (including after intermediate resizes)." This is correct under the Whiteboard model but is only safe because `zigAlloc` does not allocate from a pool where freed blocks are reused — if the arena allocator changed to one that tracks individual free slots, the no-op free would be wrong. As the sole reclamation path is `ArenaAllocator.reset(.free_all)`, this risk is currently hypothetical.

***

## `prepareMdForC`

```
pub fn prepareMdForC(md: []const u8) ApexError!struct { ptr: [*]const u8, len: usize }
```

Handles two cases:

1. `md.len == 0`: Returns `{.ptr = &empty_md_sentinel, .len = 0}`. The sentinel is a file-scope `const [1]u8 = .{0}`, which has program-lifetime address stability. The header requires `md` to be non-null even when `md_len == 0`; this satisfies that constraint without allocating or duplicating.
2. Non-empty: Checks that `md.ptr` is non-null (i.e., `@intFromPtr(md.ptr) != 0`) and returns the original pointer and length without copying.

The `&empty_md_sentinel` design has one nuance: the single byte is `\0`, so a buggy C engine that peeks one byte past `md_len == 0` reads `\0` rather than garbage. The comment in the file acknowledges this: "Safe only because the ABI forbids Apex retaining pointers after return." The sentinel address is stable for the process lifetime, which is stronger than the Whiteboard scope, so no lifetime issue arises.

**What this does not check:** whether `md.ptr` points into valid memory for `md.len` bytes. Validating the slice's extent against allocator metadata is not possible from Zig without GC or fat-pointer machinery, and is explicitly delegated to the caller.

***

## `mapRenderResult`

```
pub fn mapRenderResult(rc: c_int, out_ptr: ?[*]u8, out_len: usize) ApexError!Html
```

This is the single post-`apex_render` gate. Its logic is:

```text
rc != 0
    → rc == APEX_ERR_OOM  → error.OutOfMemory
    → else                → error.RenderFailed        (never reads out_ptr/out_len)

rc == 0 (success)
    out_ptr == null
        out_len != 0  → error.RenderFailed            (ABI violation)
        out_len == 0  → Html{ .bytes = &.{} }
    out_ptr != null
        → Html{ .bytes = base[0..out_len] }           (view, no copy)
```

The function is `pub` specifically so that it can be called directly by `apex_hostile_test.zig` and its own embedded tests with arbitrary `rc`, `out_ptr`, and `out_len` combinations, without requiring a live C call. This makes the gate logic independently verifiable.

One structural note: the conversion from `[*c]u8` (the raw C output type) to `?[*]u8` (the Zig optional many-pointer) happens in `render`, not in `mapRenderResult`. The `render` function does `const optional_ptr: ?[*]u8 = if (out_ptr == null) null else @ptrCast(out_ptr)` before passing to `mapRenderResult`. This keeps `mapRenderResult`'s type signature clean and usable from tests that do not go through `@cImport`.

**Coverage:** Eight distinct states are tested by the embedded unit tests in `apex.zig` alone, plus the hostile-double suite adds coverage of the dirty-output cases. The test for "success non-null forms slice of declared length" is the only test that constructs a real `Html.bytes` slice; all error-path tests confirm the error without inspecting any output pointer.

***

## `render` function

```
pub fn render(md: []const u8, arena: *std.heap.ArenaAllocator) ApexError!Html
```

The full call sequence:

```text
render(md, arena)
    ↓
[Debug] pre_capacity = arena.queryCapacity()
    ↓
var alloc_iface: std.mem.Allocator = arena.allocator()   // stack-lifetime
var apex_alloc: c.ApexAllocator = { .alloc=zigAlloc, .free=zigFree, .ctx=&alloc_iface }
var out_ptr: [*c]u8 = null
var out_len: usize = 0
    ↓
prepareMdForC(md)  →  { .ptr, .len }
    ↓
lockRenderMutex()
    ↓
rc = c.apex_render(ptr, len, &out_ptr, &out_len, &apex_alloc)
    ↓
unlockRenderMutex()
    ↓
[Debug] assert arena.queryCapacity() >= pre_capacity
    ↓
optional_ptr = if (out_ptr == null) null else @ptrCast(out_ptr)
    ↓
mapRenderResult(rc, optional_ptr, out_len)  →  Html or ApexError
```

Key design decisions and their rationale:

**Stack-scoped `ApexAllocator`.** The struct and `alloc_iface` are declared `var` on the Zig stack and are valid only for the synchronous duration of `apex_render`. The header contract forbids Apex from retaining these pointers after return. This is the tightest possible scope and makes lifetime violations by Apex immediately visible under ASAN.

**Pre-zeroed outputs.** `out_ptr` is initialized to `null` and `out_len` to `0` before the C call. The header says Apex also zeroes them on entry, but the Zig side does not rely on that: "C also zeros them, but we never rely on that alone."

**Mutex serialization.** `render_mutex` is a `std.atomic.Mutex` (not `std.Thread.Mutex`, which was removed in Zig 0.16 per the inline comment). The lock is acquired just before `c.apex_render` and released immediately after. Post-call assertions (debug watermark, `mapRenderResult`) run outside the lock, which is correct because they do not touch C state. The comment notes that `std.Thread.Mutex` was the prior API and that `std.Io.Mutex` requires an `Io` instance, making `std.atomic.Mutex` with yield-on-contention the right 0.16 choice.

**Debug arena capacity watermark.** In `Debug` builds only, `arena.queryCapacity()` is sampled before and after `apex_render`. The post-call assert `post_capacity >= pre_capacity` fires if something freed arena-owned blocks during the C call — which would indicate a violation of the no-libc-free contract. This does not fire in `ReleaseSafe`/`ReleaseFast`/`ReleaseSmall` builds.

**No input copy.** `prepareMdForC` returns the original pointer and length (or the static sentinel). No `dupe`, no NUL-termination, no intermediate buffer. This is the "zero-copy input" contract documented in the function's doc comment.

***

## Concurrency model

`render` is safe to call from multiple threads because of `render_mutex`. The mutex is a process-global `std.atomic.Mutex` initialized to `.unlocked`. `lockRenderMutex` spins with `std.Thread.yield()` (falling back to `std.atomic.spinLoopHint()` on yield failure) until it acquires. Only one thread executes `c.apex_render` at a time.

However, the module's own comment is explicit: "Product ApexMarkdown (and the thin host adapter) is not proven re-entrant across simultaneous `apex_render` calls." The mutex is a correctness fence, not a formal thread-safety proof. `docs/contracts/parallel-rendering.md` (D4) echoes this: "Boris does not claim a full formal proof that every ApexMarkdown global is re-entrant." The D4 smoke test (U18) in the embedded test suite spawns 8 threads each running 24 rounds of `render` on 8 distinct samples and compares results against sequential baselines; it also checks for cross-talk markers. This is evidence, not a proof.

The Whiteboards (one `ArenaAllocator` per thread in the product `--jobs` path) are per-thread; the mutex serializes only the C call. Post-call slice formation and arena reset happen outside the lock on each worker's own arena. This is correct as long as no arena memory is shared between workers, which the parallel-rendering contract (`docs/contracts/parallel-rendering.md` § Thread \& Memory Isolation) guarantees.

***

## `Html` type and lifetime contract

```zig
pub const Html = struct {
    bytes: []const u8,
    pub const owns_memory: bool = false,
};
```

`bytes` is a view of arena memory produced by the C engine's `zigAlloc` callbacks. It is valid until the arena's `reset(.free_all)` or `deinit()`. The `owns_memory = false` is a comptime documentation flag tested by `"Html documents borrowed arena lifetime"`. No field in `Html` encodes the arena it came from, so the lifetime check is a programmer discipline matter, not an enforced constraint. `forbidApexFree` panics if called — its intended use is as a guard for hypothetical future paths that might incorrectly pass an `Html` to `apex_free`; calling it on a live `Html` is always wrong by design.

***

## `remainingAbiAssumptions`

```zig
pub const remainingAbiAssumptions = [_][]const u8{ ... };
```

Eight strings. The test `"remaining ABI assumptions are non-empty audit list"` asserts exactly eight entries, each `len > 10`. This is a regression guard: accidental removal of an assumption without deliberate decision raises a test failure. The assumptions are:

1. Apex does not retain allocator/ctx/md/out pointers after return.
2. Apex does not call libc `free`/`realloc` on custom-allocator memory.
3. Apex only reads `md` within `[md, md+md_len)` (never `strlen`).
4. On success, `out_html` points at `out_len` valid bytes of host-allocator memory.
5. Apex does not write through outs after setting them and returning.
6. Apex does not invoke `alloc`/`free` after `apex_render` returns.
7. `size_t` and `usize` match (enforced comptime for this build).
8. Caller's markdown is opaque bytes; UTF-8 is validated upstream.

Item 7 is redundant with the comptime check in the same file, which is an acceptable belt-and-suspenders documentation choice. Items 1, 2, 3, 5, and 6 are the ones most dangerous if violated — they would cause use-after-stack (1), heap corruption (2), out-of-bounds C reads (3), undefined C writes (5), or use-after-free (6). None can be enforced by Zig against a hostile production binary.

***

## Threat model (as addressed by the wrapper's design)

The module's defenses are calibrated against specific classes of C misbehavior. Each defense is assessed for its enforcement type.

### Status not checked before output consumption

**Defense:** `mapRenderResult` checks `rc != 0` as the first operation and returns an error without evaluating `out_ptr` or `out_len`. This is a single, testable code path.
**Enforcement:** Directly demonstrated by `mapRenderResult` unit tests and the hostile double.
**Residual:** The check is only useful if `mapRenderResult` is the only post-call path. If future code calls `c.apex_render` directly and reads outputs without going through `mapRenderResult`, the protection is bypassed. Currently enforced by code review discipline, not a Zig type system constraint.

### Success with null pointer and nonzero length

**Defense:** `mapRenderResult` success path explicitly checks `out_ptr == null && out_len != 0` and returns `error.RenderFailed`.
**Enforcement:** Directly demonstrated by multiple tests.
**Residual:** Does not cover the case where `out_ptr` is non-null but points to invalid memory (e.g., a dangling stack address or a pointer to a region shorter than `out_len`). Zig cannot verify the extent of a `[*]u8` without allocator metadata.

### Null markdown pointer passed to C

**Defense:** `prepareMdForC` provides a non-null sentinel for the empty case. For non-empty input, it checks `@intFromPtr(md.ptr) != 0`. The header requires non-null `md` even when `md_len == 0`.
**Enforcement:** Structurally checked; tested by `prepareMdForC` unit tests.
**Residual:** Does not check that `md.ptr[0..md.len]` is entirely readable. Zig does not validate slice extents against physical address ranges.

### Arena shrinkage during C call (libc free on custom-allocator memory)

**Defense:** Debug-mode `queryCapacity()` watermark asserts capacity is non-decreasing across the C call.
**Enforcement:** Only active in `Debug` builds. Not enforced in release builds. Tests for this (`"apex render does not shrink arena capacity"`) are also guarded by `skipIfHostileEngine()` — they run only against the real engine.
**Residual:** Release builds have no runtime check. The watermark detects *capacity shrinkage* but not partial corruption of arena blocks below the low-water mark. Does not detect a C engine that reads/writes arena memory after `apex_render` returns.

### Concurrent C engine access

**Defense:** `render_mutex` serializes all `c.apex_render` calls.
**Enforcement:** Structurally enforced (the mutex is always acquired before and always released after the C call). The U18 D4 smoke test exercises concurrent rendering.
**Residual:** Serialization prevents concurrent entry but cannot prevent data races inside the C engine that arise from C-side global state mutated by one call and read by the same thread on the next call. The D4 smoke is a probabilistic witness, not a proof. Serialization also means that under `--jobs N`, rendering throughput is bounded by the single-threaded C call rate.

### `apex_free` called on arena-owned memory

**Defense:** `forbidApexFree` panics. `Html.owns_memory = false`. No call to `c.apex_free` or `std.heap.c_allocator.free` appears in the `render` path.
**Enforcement:** Code-review discipline + `forbidApexFree` as a panic guard if a future path is added. Tested by `"apex_free must not be used on arena html"` (which confirms success + `reset`, with no `apex_free` call).
**Residual:** `forbidApexFree` can only be checked if it is actually called. The test does not call it (that would panic). The protection is documentation + structural absence, not a type-level constraint.

### Retained pointers from the C engine

**Defense:** `ApexAllocator` struct is stack-local; `alloc_iface` is stack-local. Both go out of scope the moment `render` returns. A C engine that stores these pointers and uses them after return encounters a dangling reference.
**Enforcement:** Contract-only. There is no Zig mechanism to prevent a C function from storing a passed pointer. `remainingAbiAssumptions[0]` documents this explicitly.
**Residual:** Fully unenforceable from Zig. ASAN on the C side (`zig build test-apex-sanitize`) would be the only runtime detection path, and that step is explicitly documented as a skip (not a pass) when the sanitizer build fails on the host.

***
