---
rag_id: system/memory-whiteboard
rag_path: system/05-memory-whiteboard.md
category: system
tags: [memory, arena, whiteboard, performance]
related:
  - system/01-architecture-pipeline.md
  - system/06-oliver-renderer.md
  - system/07-zero-copy-assembly.md
  - system/10-name-and-metaphor.md
---

# Memory: the Whiteboard strategy

**Outcome:** each HTML page gets a temporary scratch pad that is wiped when
that page finishes — building later pages does not keep earlier render junk
alive. Durable metadata (title, parent, paths) lives separately on PageDb.

When compiling many pages, a global heap of micro-allocations fragments and
grows. Boris uses a **document-local arena** (the whiteboard) backed by Zig’s
`std.heap.ArenaAllocator`.

**Workshop analogy:** reusable workbench — wipe only after every user of this
page’s scratch is finished.  
**Invariant:** `free_all` only after the renderer returns, flush, temp
finalize, and publish attempt; no caller retains Whiteboard slices.

Default HTML path: bare `boris` → `dist/`. Tests: `src/compile.zig`,
`src/hardening_test.zig`.

## Loop shape (`src/compile.zig`)

```text
arena = ArenaAllocator.init(gpa)
for each page:
    defer arena.reset(.free_all)    # always wipe, success or error
    a = arena.allocator()
    source  = read file into a
    parsed  = frontmatter parse + Aside tokenize into a
    html    = render(markdown segments) + aside.renderHtml → a
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
| Peak document-arena capacity tracks largest page, not `N` pages, under this model | No fragmentation outside the arena (GPA, libc) |
| Unit/harness evidence on the host running `zig build test` | Multi-OS memory profile guarantees |

## Why the renderer allocates through the whiteboard

Oliver's parse and render take a caller-supplied allocator. Boris points them
at the document arena, so the document tree and the rendered HTML live on the
whiteboard and vanish on `free_all` — the same ownership the previous renderer
had via its allocator callbacks.

## Flush-before-reset

`assemble.writePage` uses a **stack** writer buffer and flushes before return.
`html_body` may point into the document arena; that memory must stay valid until
flush completes. The compile loop only runs `reset(.free_all)` after `writePage`
returns (via `defer` at the end of each iteration).
