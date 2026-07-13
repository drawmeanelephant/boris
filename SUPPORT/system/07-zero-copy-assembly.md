---
rag_id: system/zero-copy-assembly
rag_path: system/07-zero-copy-assembly.md
category: system
tags: [assembly, layout, zero-copy, html, dist]
related:
  - system/01-architecture-pipeline.md
  - system/05-memory-whiteboard.md
  - system/06-apex-native-engine.md
---

# Zero-copy layout splicing

Traditional SSGs concatenate `header + content + footer` into one huge string. Boris forbids that for final assembly.

## Layout load (once)

`layouts/main.html` is read at startup and split on the marker `{{content}}`:

- `layout.prefix` — bytes before the marker
- `layout.suffix` — bytes after the marker

Both are **slices into the original template buffer** (immutable for the process lifetime).

## Per-page write (`src/assemble.zig`)

```text
open dist/<output_path>
buffered writer:
  writeAll(layout.prefix)
  writeAll(page_html)    # already includes asides in document order
  writeAll(layout.suffix)
flush
```

No `prefix ++ html ++ suffix` allocation exists in application memory.

## Output roots

| Output | Path pattern |
|--------|----------------|
| Page HTML | `dist/<entity-path>.html` |
| RAG page segment | `rag/content/pages/<entity-path>.md` |

There are **no** per-aside fragment files under `dist/` and **no** separate aside RAG tree. Callouts live inside the page body.
