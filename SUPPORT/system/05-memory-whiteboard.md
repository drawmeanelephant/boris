---
rag_id: system/memory-whiteboard
rag_path: system/05-memory-whiteboard.md
category: system
tags: [memory, arena, whiteboard, performance]
related:
  - system/01-architecture-pipeline.md
  - system/06-apex-native-engine.md
  - system/07-zero-copy-assembly.md
---

# Memory: the Whiteboard strategy

When compiling thousands of pages, a global heap of micro-allocations fragments and grows. Boris uses a **document-local arena** (the whiteboard).

## Loop shape (`src/compile.zig`)

```text
arena = ArenaAllocator.init(gpa)
for each page:
    a = arena.allocator()
    source  = read file into a
    parsed  = parse into a
    html    = render segments (apex + components) into a
    write html to dist/
    arena.reset(.free_all)          # wipe everything for this document
```

## What survives the reset

Only data promoted into `PageDb`’s long-lived arena:

- `source_path`, `output_path`, `entity_id`
- `title`, `parent_entry` (duplicated out of document arena)

Transient data that dies each iteration:

- raw source bytes
- cleaned body markdown
- component/aside slice views (parse-time only; not stored on Page)
- Apex HTML buffer

## Flat RAM proof

After `reset(.free_all)`, `queryCapacity()` is **0**. Peak capacity stays proportional to the largest single document, not to `N` documents.

## Why Apex uses custom allocators

`apex_render` accepts an `ApexAllocator` with `alloc`/`free` callbacks. Boris points those at the document arena so HTML lives on the whiteboard and vanishes on reset. Individual `free` calls are no-ops under the arena model.
