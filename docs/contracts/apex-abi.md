# Apex C ABI contract (milestone 8)

**Status:** normative for the in-process markdown engine boundary.  
**Scope:** `vendor/apex/apex.h`, `vendor/apex/apex.c`, Zig wrapper `src/apex.zig`.  
**Not in scope (m8):** default IR / RAG pipeline wiring, HTML `dist/`, child-process render.

This document divides guarantees into:

1. **Mechanically checked by Zig** (comptime / wrapper logic)
2. **Tested behavior** (unit + hostile + optional sanitizer)
3. **Vendor contract / remaining assumption** (Zig cannot prove against arbitrary buggy C)

---

## Exact `apex.h` ABI

```c
#define APEX_OK        0
#define APEX_ERR_ARGS  1
#define APEX_ERR_OOM   2

typedef void *(*apex_alloc_fn)(void *ctx, size_t size);
typedef void  (*apex_free_fn)(void *ctx, void *ptr, size_t size);

typedef struct ApexAllocator {
    apex_alloc_fn alloc;  /* required when allocator != NULL */
    apex_free_fn  free;   /* optional; NULL means no-op free */
    void *ctx;            /* opaque host context */
} ApexAllocator;

int apex_render(
    const char *md,              /* non-NULL; need not be NUL-terminated */
    size_t md_len,               /* byte length; bounds all md reads */
    char **out_html,             /* out: buffer or NULL */
    size_t *out_len,             /* out: byte length */
    const ApexAllocator *allocator  /* NULL → libc malloc path */
);

void apex_free(char *html, size_t len);  /* libc path only */
const char *apex_version(void);          /* static storage; never free */
```

### Status codes

| Code | Value | Meaning |
|------|-------|---------|
| `APEX_OK` | 0 | Success; `out_html` / `out_len` describe the buffer |
| `APEX_ERR_ARGS` | 1 | Invalid arguments (null required pointers, incomplete allocator) |
| `APEX_ERR_OOM` | 2 | Allocation failure through the active allocator |
| other non-zero | — | Reserved; hosts treat any non-zero as failure |

Zig maps: `APEX_ERR_OOM` → `error.OutOfMemory`; all other non-zero → `error.RenderFailed`.

---

## Allocator callback lifetime contract

### Host (Zig / Boris)

| Rule | Detail |
|------|--------|
| Call-scoped `ApexAllocator` | Struct and `ctx` live on the **stack** for the duration of `apex_render` only (Whiteboard path). |
| `ctx` type | `*std.mem.Allocator` pointing at the document arena’s allocator interface. |
| `alloc` | Forwards to arena `alloc(u8, size)`. Returns null on failure. Zero-size returns a non-null pointer when the arena allows it. |
| `free` | **Hard no-op** (`zigFree`). Intermediate C resizes must not return memory to the GPA. |
| Output ownership | HTML bytes are **borrowed** from the arena. Reclaim only via `ArenaAllocator.reset(.free_all)` / `deinit`. |
| Forbidden | Calling `apex_free` or libc `free` on arena-owned HTML (`forbidApexFree` panics if used as a guard). |

### Engine (Apex C)

| Rule | Detail |
|------|--------|
| Supplied allocator | When `allocator != NULL`, **all** output and scratch use `allocator->alloc`. No `malloc`/`free` on that path. |
| Free routing | Intermediate frees go through `allocator->free` if non-null; otherwise treated as no-op. |
| No retention | After `apex_render` returns, Apex must not retain pointers to: allocator struct, `ctx`, input markdown, output HTML, or any allocation obtained during the call. |
| Synchronous only | No threads, no deferred callbacks, no hidden global mutable render state, no process spawning. |
| Libc path | `allocator == NULL` uses `malloc`; caller must free with `apex_free` only. Boris Whiteboard never uses this path. |

---

## C and Zig error-handling rules

### C engine (`apex_render`)

1. On entry (when `out_html` / `out_len` are non-null): set `*out_html = NULL`, `*out_len = 0`.
2. Null `out_html`, `out_len`, or `md` → `APEX_ERR_ARGS` (outputs cleared when pointers allow).
3. Custom allocator with null `alloc` → `APEX_ERR_ARGS`.
4. Allocation failure or internal grow overflow → free intermediate buffer via host free hook → `*out_html = NULL`, `*out_len = 0` → `APEX_ERR_OOM`.
5. Overflow checks before allocation-size arithmetic (`size_t` wrap on grow/append).
6. On success: `*out_html` / `*out_len` describe the buffer; empty document may leave null + zero.
7. No writes through output parameters after return.

### Zig wrapper (`src/apex.zig`)

1. Create `out_html` / `out_len` in a defined state (`null` / `0`) before the C call.
2. **Check status before interpreting outputs.** Non-zero `rc` never constructs a slice from dirty outs.
3. Success + null pointer + nonzero length → `error.RenderFailed`.
4. Success + null + zero → empty `Html`.
5. Success + non-null → `Html{ .bytes = ptr[0..len] }` (view, no copy).
6. Length conversions: comptime assert `usize` matches C `size_t`; no truncating casts.
7. Checked arithmetic for allocator sizing helpers; zero-byte alloc handled safely.
8. Allocation failure from C → `error.OutOfMemory`.
9. Never call `apex_free` on Whiteboard output.

---

## Property classification

### Mechanically checked by Zig

| Property | How |
|----------|-----|
| Declarations match `apex.h` | `@cImport` / `@cInclude("apex.h")` — not hand-copied types |
| `usize` / `size_t` width for lengths | comptime on `apex_render` params |
| `apex_render` arity | comptime |
| Status constant values | comptime + unit test |
| `ApexAllocator` field count | comptime |
| Status-before-outputs gate | `mapRenderResult` single post-call path |
| Null + nonzero length rejection | `mapRenderResult` |
| No `apex_free` on arena path | code path; `forbidApexFree` panic guard; `Html.owns_memory == false` |
| Debug capacity watermark | assert arena capacity does not shrink across `apex_render` |

### Tested behavior

| Property | Coverage |
|----------|----------|
| Empty markdown | unit test |
| Typical markdown (headings, bold, paragraph) | unit test via real `@cImport` |
| Input not NUL-terminated | unit test (slice into larger buffer) |
| Large input (≥ 64 KiB bound) | unit test |
| Forced allocation failure → `OutOfMemory` | fixed-buffer arena test |
| C success null + zero length | `mapRenderResult` + empty render |
| C success null + nonzero length rejected | `mapRenderResult` + hostile double |
| Nonzero error status with hostile outputs not read | `mapRenderResult` + `zig build test-apex-hostile` |
| Arena free callback safe / no-op | large render (forces C intermediate free) |
| Version string linked | unit test |
| Optional ASan+UBSan C smoke | `zig build test-apex-sanitize` when host supports it |

### Vendor contract / remaining assumptions

Zig cannot mathematically prove these against an arbitrary buggy production Apex binary. They are **required** of any linked engine and listed in `remainingAbiAssumptions` in `src/apex.zig`:

- Apex does not retain allocator / ctx / md / out pointers after return (synchronous only).
- Apex does not call libc `free`/`realloc` on custom-allocator memory.
- Apex only reads `md` within `[md, md+md_len)` (never `strlen` on md).
- On success, `out_html` points at `out_len` valid host-allocator bytes.
- Apex does not write through outs or invoke alloc/free after return.
- Caller’s markdown is opaque bytes; UTF-8 is validated upstream on compile paths.

---

## Build integration

| Step | Role |
|------|------|
| `zig build` | Links `vendor/apex/apex.c` into `boris` (default CLI does not call Apex) |
| `zig build test` | Includes Apex wrapper tests against the real engine |
| `zig build test-apex-hostile` | Links `apex_hostile.c`; proves status-first wrapper |
| `zig build test-apex-sanitize` | Optional ASan+UBSan C smoke; **documents skip** if unavailable |

Flags: `link_libc`, include `vendor/apex`, C11 sources. No child-process markdown renderer.

---

## Engine: ApexMarkdown Unified adapter

`vendor/apex/apex.c` is a **thin host adapter** (Feature 1 Chat 3), not a
hand-rolled markdown parser. It keeps this host ABI and implements:

```text
apex_render → apex_markdown_to_html (APEX_MODE_UNIFIED, fragment HTML)
           → copy into host allocator (Whiteboard / libc path)
           → apex_free_string (release upstream heap; no Apex ptrs retained)
```

| Boundary setting | Value | Why |
|------------------|-------|-----|
| Mode | `APEX_MODE_UNIFIED` | Product default (all Apex features) |
| `standalone` | false | Layout splice owns chrome |
| `pretty` | false | Stable compact HTML |
| `unsafe` | true | Trusted author content; raw HTML allowed |
| File includes | off | Boris expands `{{include}}` in Zig before Apex; never enable Apex FS includes |
| Plugins | off | Subprocess / untrusted code risk |
| External plugin detection | off | No CWD/global `.apex/plugins` probe |
| External highlighters | off | AGENTS forbids MD CLI spawn |

Real engine sources: `vendor/apex-markdown/` ([VENDOR.md](../../vendor/apex-markdown/VENDOR.md)).
cmark-gfm is **only** Apex’s upstream substrate — not Boris’s public renderer.
Host include guard is `BORIS_APEX_HOST_H` (not `APEX_H`) so the adapter can
include both host and upstream headers. Historical campaign notes (optional):
[`archive/docs/reviews/feature-1-apex-fidelity-spec.md`](../../archive/docs/reviews/feature-1-apex-fidelity-spec.md).

---

## Explicit non-goals (m8 / host ABI)

- Wiring Apex into IR emit or RAG export (HTML path only)
- Spawning external markdown processes
- Exposing every Apex mode/option on the CLI (product is Unified-only)
