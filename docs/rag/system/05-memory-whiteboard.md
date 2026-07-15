---
rag_id: system/memory-whiteboard
rag_path: system/05-memory-whiteboard.md
category: system
tags: [memory, arena, whiteboard, performance]
related:
  - system/01-architecture-pipeline.md
  - system/06-apex-native-engine.md
  - system/07-zero-copy-assembly.md
  - system/10-name-and-metaphor.md
---

# Memory: the Whiteboard strategy

When compiling many pages on the HTML path, a global heap of micro-allocations
fragments and grows. Boris uses a **document-local arena** (the whiteboard)
backed by Zig’s `std.heap.ArenaAllocator`.

**Workshop analogy:** reusable workbench — wipe only after every user of this
page’s scratch is finished.  
**Invariant:** `free_all` only after Apex return, flush, temp finalize, and
publish attempt; no caller retains Whiteboard slices.

This path is **opt-in relative to the v0.1 default CLI** (IR under
`.boris/`). Whiteboard behavior is exercised by tests in `src/compile.zig` and
`src/hardening_test.zig`.

## Loop shape (`src/compile.zig`)

```text
arena = ArenaAllocator.init(gpa)
for each page:
    defer arena.reset(.free_all)    # always wipe, success or error
    a = arena.allocator()
    source  = read file into a
    parsed  = frontmatter parse + Aside tokenize into a
    html    = Apex(markdown segments) + aside.renderHtml → a
    writePage(...); flush completes before return
    # then defer free_all — never reset while buffered write is in flight
```

## What survives the reset

Only data promoted into `PageDb`’s long-lived retain arena:

- `source_path`, `output_path`, `entity_id`
- `title`, `parent`, `status`, `tags` (duplicated at promote)

**Workshop analogy:** permanent card catalog vs temporary workbench notes.  
**Invariant:** never store a raw parse slice on PageDb.

Transient data that dies each iteration:

- raw source bytes
- cleaned body markdown
- component/aside slice views (parse-time only; not stored on Page)
- Apex HTML buffer

## Flat RAM — what is actually tested

After `reset(.free_all)`, tests assert `queryCapacity()` is **0** for the
document `ArenaAllocator` used in the compile loop
(`proveFlatFootprint` / harness isolation tests).

**Claim scope (do not overstate):**

| Claimed | Not claimed |
|---------|-------------|
| Document arena returns to 0 capacity after `free_all` in tested loops | Process RSS stays flat under all OS allocators |
| Peak document-arena capacity tracks largest page, not `N` pages, under this model | No fragmentation outside the arena (GPA, libc, Apex stub internals) |
| Unit/harness evidence on the host running `zig build test` | Multi-OS memory profile guarantees |

## Why Apex uses custom allocators

`apex_render` accepts an `ApexAllocator` with `alloc`/`free` callbacks. Boris
points those at the document arena so HTML lives on the whiteboard and vanishes
on reset. Individual `free` calls are no-ops under the arena model.

## Flush-before-reset

`assemble.writePage` uses a **stack** writer buffer and flushes before return.
`html_body` may point into the document arena; that memory must stay valid until
flush completes. The compile loop only runs `reset(.free_all)` after `writePage`
returns (via `defer` at the end of each iteration).
