---
title: "`src/render.zig` surface and execution"
id: docs/boris/src/render/surface-and-execution
parent: docs/boris/src/render
status: draft
tags: [boris, zig, source-reference, surface, render]
---

# `src/render.zig` surface and execution

## Public API surface

### `RenderError`

```zig
pub const RenderError = error{
    OutOfMemory,
    InputTooLarge,
    WriteFailed,
    NoSpaceLeft,
};
```

The error set surfaced by the seam. `InputTooLarge` is Oliver's documented
input-size bound (`max_input_len`, checked before any markup interpretation);
`WriteFailed` / `NoSpaceLeft` come from the output writer; everything else maps
to `OutOfMemory`.

### `Html`

```zig
pub const Html = struct { bytes: []const u8 };
```

A view of Whiteboard (arena) memory produced by `render`. Valid only until the
arena is reset or deinitialized; never freed individually.

### `test_large_md_bytes`

Bounded stress size (64 KiB) for large-input tests, keeping CI bounded.

### `render(md, arena)`

```zig
pub fn render(md: []const u8, arena: *std.heap.ArenaAllocator) RenderError!Html
```

Parses `md` with Oliver (dialect options: `footnotes`, `definition_lists`,
`heading_attributes`) and renders HTML (options: `heading_ids`, `footnotes`)
into the Whiteboard arena, returning a borrowed view of the produced bytes.

## Execution notes

- Oliver's `Document` wraps its backing allocator in its own arena; passing the
  Whiteboard allocator means the document tree and rendered bytes live on the
  Whiteboard and vanish on `free_all`.
- The renderer never reads files or the environment; includes and wiki-links
  are Boris-mediated before the seam runs.
- Diagnostics from the previous C engine (mutex serialization, ABI status
  gates, `@cImport` comptime checks) no longer exist; Oliver is pure Zig.
