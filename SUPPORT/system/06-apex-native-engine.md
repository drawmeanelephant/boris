---
rag_id: system/apex-native-engine
rag_path: system/06-apex-native-engine.md
category: system
tags: [apex, c-abi, markdown, performance, cImport]
related:
  - system/01-architecture-pipeline.md
  - system/05-memory-whiteboard.md
  - system/07-zero-copy-assembly.md
---

# Apex: native C-ABI markdown engine

Apex is the markdown renderer. In Boris it is **not** invoked as a CLI. It is compiled as C, linked into the binary, and called through Zig `@cImport`.

## Why not spawn processes

Spawning a process per page (`std.process.Child` / historical `ChildProcess`) costs OS context switches and startup. For thousands of files that destroys throughput. Boris treats rendering as:

```text
markdown pointer + length  →  apex_render(...)  →  HTML pointer + length
```

## C API (`vendor/apex/apex.h`)

```c
typedef struct ApexAllocator {
    void *(*alloc)(void *ctx, size_t size);
    void  (*free)(void *ctx, void *ptr, size_t size);
    void *ctx;
} ApexAllocator;

int apex_render(
    const char *md, size_t md_len,
    char **out_html, size_t *out_len,
    const ApexAllocator *allocator);

void apex_free(char *html, size_t len);
const char *apex_version(void);
```

Status codes: `APEX_OK` (0), `APEX_ERR_ARGS` (1), `APEX_ERR_OOM` (2).

## Lifetime contracts (normative)

- **Synchronous only** — no deferred alloc/free after `apex_render` returns.
- **Stack / call lifetime** — host may place `ApexAllocator` + `ctx` on the stack for the call (Boris does). Apex must not retain allocator, ctx, input, or output pointers after return.
- **Custom allocator** — all scratch/output via `alloc`; `free` may be a no-op (Whiteboard). Apex must not libc `free`/`realloc` custom-allocator memory.
- **Never `apex_free` on arena HTML** — `apex_free` is only for the libc-malloc path (`allocator == NULL`).
- **On error** — C clears `*out_html` / `*out_len`; host still must check status **before** reading outputs.

## Zig wrapper (`src/apex.zig`)

- `@cImport({ @cInclude("apex.h"); })`
- Pre-init `out_html=null`, `out_len=0`; empty md uses a non-null sentinel pointer
- Stack-local `ApexAllocator` + `std.mem.Allocator` iface (not global)
- Arena-backed `zigAlloc` / no-op `zigFree`
- `mapRenderResult`: status first; reject null+nonzero length; then form slice
- Returns `Html{ .bytes = out_ptr[0..out_len] }` only after all checks
- Compiles `usize`/`size_t` width match at comptime

## Build linkage (`build.zig`)

- `link_libc = true`
- `addCSourceFile(vendor/apex/apex.c)` with `-std=c11 -Wall -Wextra`
- `addIncludePath(vendor/apex)`
- Optional: `zig build test-apex-sanitize` → `zig cc -fsanitize=address,undefined` smoke binary

## Stub vs production

`vendor/apex/apex.c` is a **minimal stub** (headings, paragraphs, bold/italic/code, raw HTML lines). A production Apex library can replace the `.c` while keeping the same header ABI and lifetime contracts.

## Remaining assumptions (not mechanically enforced)

Memory safety of a replaced Apex binary cannot be proved by Zig tests alone. See `remainingAbiAssumptions` in `src/apex.zig` (non-retention, no libc free on arena bytes, in-bounds `out_len`, no post-return callbacks, UTF-8 gated upstream on the compile path).
