---
rag_id: system/zero-copy-assembly
rag_path: system/07-zero-copy-assembly.md
category: system
tags: [assembly, layout, zero-copy, html, dist]
related:
  - system/01-architecture-pipeline.md
  - system/05-memory-whiteboard.md
  - system/06-apex-native-engine.md
  - system/08-build-cli-and-layout.md
  - system/10-name-and-metaphor.md
---

# Zero-copy layout splicing

Traditional SSGs concatenate `header + content + footer` into one huge string.
Boris forbids that for final assembly.

Metaphorically this is **improvisation under constraint** (the **Ignite** write
path): when rebuilding the middle would waste work, stream the pieces you already
have — layout prefix, page body, layout suffix — straight to the output. See
[system/10-name-and-metaphor.md](10-name-and-metaphor.md).

## Layout load (once, before content scan)

`layouts/main.html` is read at **startup** and split on the marker `{{content}}`:

- `layout.prefix` — `[]const u8` bytes before the marker
- `layout.suffix` — `[]const u8` bytes after the marker

Both are **slices into the original template buffer** (`layout.raw`). The owning
`Layout` object (and its arena) must outlive every `writePage` call.

Hard errors at load (no content walk yet):

| Condition | Error |
|-----------|--------|
| No `{{content}}` | `MissingContentMarker` |
| Two or more `{{content}}` | `DuplicateContentMarker` |

Site entry order: **layout → scan → precreate dist dirs → compile loop**.

## Per-page write (`src/assemble.zig`)

```text
createFileAtomic(output_path, replace=true, make_path=true)
  → unique temp name (hex u64) in destination directory
buffered writer (64 KiB **stack** buffer, not arena):
  writeAll(layout.prefix)
  writeAll(page_html)    # already includes asides in document order
  writeAll(layout.suffix)
flush
Atomic.replace → rename temp → final path
Atomic.deinit on failure → delete only this op's temp
```

No `prefix ++ html ++ suffix` allocation exists in application memory.

`page_html` is typically a Whiteboard slice. Callers must not
`arena.reset(.free_all)` until `writePage` returns (after flush + replace).

## Publish semantics

| Property | Behavior |
|----------|----------|
| Temp naming | Unique per operation via Zig 0.16 `createFileAtomic` (not fixed `*.tmp`) |
| Collision | Independent Boris processes use distinct temp basenames in the dest dir |
| On write failure | Only the current temp is cleaned; prior final file is preserved |
| Destination replace | Same-directory rename replace; exercised by unit tests on the **host OS** running `zig build test` |

**Explicitly not claimed:**

- Atomic output replacement on **all** platforms / filesystems without multi-OS CI
- Cross-device / cross-volume atomic rename
- Windows: Zig std documents a brief window where concurrent openers of the
  destination may see `error.AccessDenied` during replace
- Atomic replacement for **IR** JSON under `.boris/` (those use ordinary `writeFile`)

This module is **HTML path only** and is not the default v0.1 CLI surface.

## Flush-before-reset (cross-cutting invariant)

Shared by memory safety and I/O correctness:

1. `writePage` flushes the stack-buffered writer fully.
2. Then renames temp → final (`Atomic.replace`).
3. Then returns.
4. Only then may `compile.zig` run `doc_arena.reset(.free_all)`.

An explicit unit test proves the published file remains complete after free_all.
Fault-injection tests prove prior output survival and temp cleanup on failure.

## Content I/O edge cases

| Case | Behavior |
|------|----------|
| Non-UTF-8 source | Hard error (`InvalidUtf8` / `E_ENCODING` on IR path) |
| Empty `.md` | Valid empty page (no frontmatter, empty body) |
| Unclosed frontmatter `---` | Hard parse error (does not swallow file as frontmatter) |
| Disk-full / mid-write fail | Temp file discarded; final path not updated |

## Output roots

| Output | Path pattern |
|--------|----------------|
| Page HTML | `dist/<entity-path>.html` |
| RAG page segment | `rag/content/pages/<entity-path>.md` |

There are **no** per-aside fragment files under `dist/` and **no** separate aside
RAG tree. Callouts live inside the page body.
