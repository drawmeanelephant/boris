---
rag_id: system/oliver-renderer
rag_path: system/06-oliver-renderer.md
category: system
tags: [oliver, markdown, rendering, performance, zig]
related:
  - system/01-architecture-pipeline.md
  - system/05-memory-whiteboard.md
  - system/07-zero-copy-assembly.md
---

# Oliver: native Zig markdown renderer

**Workshop analogy:** in-house typesetting machine on the shop floor.  \
**Invariant:** native Zig library call; no global state, no retained pointers,
no clock/network/filesystem access; never a child-process markdown renderer.

Oliver is the markdown renderer used by the **HTML** path (default CLI under
`dist/`, and Aside inner bodies). It is a freestanding Zig library pinned by
content hash in `build.zig.zon` (see `docs/contracts/oliver-renderer.md` for
the exact revision and the upgrade procedure). Boris calls it through a single
seam, `src/render.zig`, which parses the body and renders HTML into the caller's
Whiteboard arena. JSON IR (`--out`) and RAG export do **not** render markdown.

## Why not spawn processes

Spawning a process per page costs OS context switches and startup. Boris treats
rendering as:

```text
markdown slice  →  oliver.parse(...)  →  typed document  →  oliver.html.render(...)  →  HTML bytes
```

## The seam (`src/render.zig`)

- `oliver.parse(arena, md, .markdown, .{ .markdown = .{ footnotes, definition_lists, heading_attributes } })`
- `oliver.html.render(arena, writer, &document, .{ .heading_ids, .footnotes })`
- Input `md` is a slice into Whiteboard arena memory; Oliver borrows it
  (text nodes slice into it) for the duration of the call.
- All produced bytes live on the Whiteboard arena; the returned `Html.bytes`
  view is valid until `arena.reset(.free_all)` — the same lifetime contract
  the previous renderer's `Html` had.
- No `@cImport`, no libc, no mutex: Oliver is pure Zig with no global state,
  so parallel `--jobs` workers on independent arenas are safe.

## What Boris still owns (the boundary)

Oliver never sees files, frontmatter, includes, wiki-links, assets, the graph,
layouts, or publication paths. Boris expands `{{include}}`, rewrites
`[[wiki-links]]` and Markdown image destinations, tokenizes `<Aside>` bodies,
then hands each markdown segment to the seam. Layout splice, staging, and
publication remain in `assemble.zig` / `compile.zig`.

## Dialect

Oliver is byte-exact CommonMark 0.31.2 (652/652 conformance) plus GFM tables,
with optional extensions Boris enables: heading auto-ids (`heading_ids`),
heading attribute lists (`heading_attributes`), footnotes (`footnotes`), and
definition lists (`definition_lists`). Raw HTML in trusted author content
passes through unescaped (unchanged raw-HTML policy). Apex-only extensions the
old renderer provided (math, callouts, task lists, fenced divs, smart
typography, captions, strikethrough) are not rendered; the compatibility wall
in `docs/contracts/oliver-renderer.md` classifies every output delta.

## Build linkage (`build.zig`)

- `b.dependency("oliver", .{ .target, .optimize })` → `oliver_mod`
- `render_mod` imports the `oliver` module; every module that transitively
  imports `src/render.zig` gets the `oliver` import via `linkOliver()`
- No libc, no CMake, no host tools; the package is fetched once by Zig and
  content-verified from `build.zig.zon`
