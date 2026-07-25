---
title: "`src/apex.zig` evidence and cases"
id: docs/boris/src/apex/evidence-and-cases
parent: docs/boris/src/apex
status: draft
tags: [boris, zig, source-reference, evidence, apex]
---

# `src/apex.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `apex version linked` | test | Real engine version string format and presence | `version()` | Non-empty; contains `"apex-markdown"` and `"unified"` (skipped under hostile) | ABI symbol; `apex_version` static storage |
| `apex render heading in-process` | test | Basic real render round-trip | `"# Hello **world**\n\nParagraph.\n"` | HTML contains `<h1`, `<strong>world</strong>`, `<p>` | `render`; `mapRenderResult` success path |
| `apex dual-run HTML is byte-identical on one host` | test | Determinism across two arenas | Same markdown, two arenas | `expectEqualStrings(a.bytes, b.bytes)` | Deterministic output contract |
| `apex render empty md is zero-copy ptr+len path` | test | Empty input; sentinel path | `""` | `html.bytes.len == 0` | `prepareMdForC` empty sentinel; C zero-output success |
| `apex render empty via zero-length slice of real buffer` | test | Empty slice into non-empty buffer | `buf[0..0]` where buf = `"not empty"` | `html.bytes.len == 0` | Non-null ptr with zero length input |
| `apex html slice is a view of whiteboard memory` | test | `Html.bytes` is arena memory, not a Zig copy | `"## Title\n\nbody\n"` | Non-empty; contains `<h2`; ptr non-null; after `reset(.free_all)` capacity == 0 | Zero-copy output; arena reclaim |
| `apex render does not shrink arena capacity (debug watermark)` | test | Capacity assertion survives two renders | Warm + second render | Capacity after ≥ capacity before | Debug watermark logic |
| `apex large input within bounded test limit` | test | 64 KiB of markdown does not crash or OOM | Built `ArrayList` of repeated lines | Non-empty HTML with expected tags | Large input handling |
| `apex invalid utf8 bytes do not crash` | test | Byte-oriented C call with non-UTF-8 input | `"hello \xff\xfe world\n\n# \x80 title\n"` | Returns `Html` (no panic, no UB) | Byte-oriented ABI; upstream UTF-8 gate |
| `apex forced allocation failure returns OutOfMemory` | test | Fixed-buffer arena exhaustion → C returns `APEX_ERR_OOM` | 128-byte FBA, sufficient markdown to overflow | `error.OutOfMemory` | OOM path; `zigAlloc` returning null |
| `apex input is not required to be NUL-terminated` | test | Slice into larger buffer with poison suffix | `storage[0..13]` of `"Hi **there**\nPOISON\xff\xff\xff"` | HTML contains `"there"`, not `"POISON"` | `md_len`-bounded read (not `strlen`) assumption |
| `apex free callback is no-op under arena` | test | Large render forces C intermediate `free`; prior bytes survive | ~20 KB of markdown | HTML len > 256; contains expected tags; capacity 0 after reset | `zigFree` no-op; arena bulk reclaim only |
| `Html documents borrowed arena lifetime` | test | `Html.owns_memory == false` | Constant check | `!Html.owns_memory` | Lifetime documentation invariant |
| `zigAlloc zero-size path is safe` | test | Zero-size path via empty render | `""` | `html.bytes.len == 0`, no crash | `zigAlloc` zero-size branch |
| `mapRenderResult: OOM status ignores dirty outputs` | test | `APEX_ERR_OOM` with non-null ptr + huge len | Fabricated values | `error.OutOfMemory` | Status-first gate |
| `mapRenderResult: args error ignores dirty outputs` | test | `APEX_ERR_ARGS` with non-null ptr + len 2 | Fabricated values | `error.RenderFailed` | Status-first gate |
| `mapRenderResult: unknown nonzero status ignores null and nonzero len` | test | Status 99 with null + `0xdeadbeef` | Fabricated values | `error.RenderFailed` | Unknown non-zero → RenderFailed |
| `mapRenderResult: reserved upstream NULL status is render failure, not OOM` | test | Status 3 (reserved, not OOM) | Fabricated values | `error.RenderFailed` | Only APEX_ERR_OOM (2) → OutOfMemory |
| `mapRenderResult: success null with nonzero len is rejected` | test | ABI violation: APEX_OK + null + 42 | Fabricated values | `error.RenderFailed` | Null+nonzero rejection |
| `mapRenderResult: success null with zero len is empty html` | test | APEX_OK + null + 0 → empty | Fabricated values | `html.bytes.len == 0` | Empty success |
| `mapRenderResult: success non-null forms slice of declared length` | test | Normal success slice | `mapRenderResult(OK, &buf, 2)` where buf=`"hi"` | `"hi"` | Slice construction |
| `mapRenderResult: success non-null zero length is empty view` | test | Non-null ptr with zero length | `mapRenderResult(OK, &buf, 0)` | `len == 0` | Zero-length view |
| `prepareMdForC empty uses non-null sentinel` | test | Empty → static sentinel | `prepareMdForC("")` | `len == 0`, `ptr != 0` | Non-null md for zero-length |
| `prepareMdForC non-empty preserves pointer and length` | test | Non-empty → original ptr | `prepareMdForC("abc")` | Same ptr, len == 3 | Zero-copy input |
| `remaining ABI assumptions are non-empty audit list` | test | Assumption registry count | `remainingAbiAssumptions.len` | `== 8`, each `len > 10` | Assumption count regression guard |
| `apex_free must not be used on arena html` | test | Documents that no `apex_free` call occurs on arena HTML | `render("x\n")` + `reset(.free_all)` | Succeeds; no `apex_free` invoked | No-apex-free-on-arena contract |
| `status constants match documented C ABI` | test | Runtime constant check | `c.APEX_OK`, `c.APEX_ERR_ARGS`, `c.APEX_ERR_OOM` | 0, 1, 2 respectively | Status constant contract |
| U1–U18 fidelity tests | tests (skipped under hostile) | GFM table, lists, blockquote, fenced code, strikethrough, task list, footnote, definition list, math, callout, IAL, fenced div, empty/non-NUL input, OOM, trusted HTML, dual-run, include-disabled, concurrent renders (D4 smoke) | Various Markdown inputs + golden strings | HTML substring and golden-string equality; U18 concurrency cross-talk markers absent | Unified fidelity pin; D4 concurrency |
| `fidelityContains` / `fidelityRender` / `fidelityEqualGolden` | helpers | Shared assertion utilities for U-tests | Internal | Fail with diagnostic on mismatch | N/A (helpers) |


***

## Control flow

### Successful render (non-empty markdown)

```text
caller
    → render(md, arena)
        → arena.queryCapacity()                     [Debug only]
        → arena.allocator()                         → alloc_iface  (stack)
        → ApexAllocator{ zigAlloc, zigFree, ctx }   (stack)
        → out_ptr = null, out_len = 0
        → prepareMdForC(md)                         → {ptr, len}
        → lockRenderMutex()
        → c.apex_render(ptr, len, &out_ptr, &out_len, &apex_alloc)
                ↓  [inside vendor/apex/apex.c]
                apex_markdown_to_html(APEX_MODE_UNIFIED, ...)
                    → zigAlloc(ctx, size) × N       ← alloc callbacks
                    → zigFree(ctx, ptr, size) × M   ← no-op resize frees
                *out_html = arena_buf_ptr
                *out_len  = html_byte_count
                return APEX_OK (0)
        → unlockRenderMutex()
        → assert post_capacity >= pre_capacity      [Debug only]
        → optional_ptr = @ptrCast(out_ptr)
        → mapRenderResult(0, optional_ptr, out_len)
              rc == 0
              out_ptr != null
              → Html{ .bytes = base[0..out_len] }
        → return Html
    ← caller receives Html (arena view)
```


### Error path (OOM example)

```text
caller
    → render(md, arena)
        → [same setup as above]
        → c.apex_render(...)
                → zigAlloc(ctx, size) returns null   ← arena exhausted
                *out_html = NULL, *out_len = 0
                return APEX_ERR_OOM (2)
        → unlockRenderMutex()
        → mapRenderResult(2, null, 0)
              rc != 0
              rc == APEX_ERR_OOM
              → return error.OutOfMemory
    ← caller receives error.OutOfMemory
```


### Empty input path

```text
caller
    → render("", arena)
        → prepareMdForC("")
              md.len == 0
              → { .ptr = &empty_md_sentinel, .len = 0 }
        → lockRenderMutex()
        → c.apex_render(&sentinel, 0, &out_ptr, &out_len, &apex_alloc)
                md_len == 0  →  *out_html = NULL, *out_len = 0, APEX_OK
        → unlockRenderMutex()
        → mapRenderResult(0, null, 0)
              rc == 0, out_ptr == null, out_len == 0
              → Html{ .bytes = &.{} }
    ← caller receives Html{ .bytes = "" }
```


***
