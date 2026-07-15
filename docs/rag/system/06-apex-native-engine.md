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

**Workshop analogy:** in-house typesetting machine on the shop floor.  
**Invariant:** synchronous C ABI call; no retained pointers after `apex_render`
returns; never a child-process markdown renderer.

Apex is the markdown renderer used by the **opt-in HTML** path (and
Aside inner bodies). The Boris **host** ABI (`vendor/apex/apex.h`) is frozen;
the host adapter calls real **ApexMarkdown Unified** (`vendor/apex-markdown`,
pinned) via `apex_markdown_to_html`, then copies HTML into the Whiteboard
allocator. Default v0.1 CLI (JSON IR) and RAG export do **not** call Apex.

## Why not spawn processes

Spawning a process per page costs OS context switches and startup. Boris treats
rendering as:

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

## Zig wrapper (`src/apex.zig`)

- `@cImport({ @cInclude("apex.h"); })`
- Passes `md.ptr` / `md.len` without intermediate string copies
- Supplies arena-backed `zigAlloc` / no-op `zigFree`
- Takes `*std.heap.ArenaAllocator` (document Whiteboard), not a bare GPA
- Returns `Html{ .bytes = out_ptr[0..out_len] }`
- **Never** calls `apex_free` on arena HTML; `forbidApexFree` panics if a future path tries
- Debug builds assert arena capacity does not shrink across `apex_render`
- Status checked **before** constructing any output slice; null+nonzero length rejected

## ABI contracts (Zig ↔ Apex C)

Hard requirements for any production Apex replacement (enforced or tested on
the Zig side where possible):

1. **Synchronous only** — `apex_render` must not defer work that uses the
   allocator after return. The Zig wrapper places `ApexAllocator` on the stack.
2. **No retained pointers (required of C)** — Apex must not cache/intern/pool any
   pointer from `ApexAllocator` beyond the call. Boris wipes the arena with
   `reset(.free_all)` between pages; retained pointers become use-after-free.
3. **No `apex_free` on arena HTML** — `apex_free` is only for the libc-malloc
   path (`allocator == NULL`). Whiteboard HTML is reclaimed solely by arena reset.
4. **Input is ptr+len** — no requirement that markdown be NUL-terminated.

### What is mechanically verified vs assumed

| Item | Verification |
|------|----------------|
| Stack-lifetime allocator; status-before-outputs; null+len reject | Unit tests + hostile/mock outputs |
| Zig never calls `apex_free` on arena HTML | Code path + panic guard |
| `usize` / `size_t` width match | Comptime check |
| Empty / large (64KiB) / invalid UTF-8 / forced OOM | Module tests |
| Hostile C double (`zig build test-apex-hostile`) | Optional step |
| ASan+UBSan smoke (`zig build test-apex-sanitize`) | Optional step |
| **C engine never retains pointers after return** | **Assumption** listed in `remainingAbiAssumptions` — not provable by Zig alone against a buggy production binary |

Do **not** document “Apex never retains pointers” as a mathematical guarantee;
document it as a **required contract** of any linked engine, with tests that
catch known failure modes and a remaining-assumptions list for auditors.

## Build linkage (`build.zig`)

- `link_libc = true`
- CMake sub-step: `scripts/build-apex-markdown.sh` → static `libapex.a` + cmark-gfm
- `addCSourceFile(vendor/apex/apex.c)` host adapter
- `addIncludePath(vendor/apex)` for Zig `@cImport` (host ABI only)
- Product modules link static ApexMarkdown archives; hostile path does not

## Engine: ApexMarkdown Unified adapter

`vendor/apex/apex.c` is a thin adapter (not a hand-rolled markdown subset).
Default mode is Unified; file includes, plugins, and external highlighters are
off at the Boris boundary. See `docs/contracts/apex-abi.md` and
`vendor/apex-markdown/VENDOR.md`.
