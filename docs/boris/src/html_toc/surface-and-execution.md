---
title: "`src/html_toc.zig` surface and execution"
id: docs/boris/src/html_toc/surface-and-execution
parent: docs/boris/src/html_toc
status: draft
tags: [boris, zig, source-reference, surface, html_toc]
---

# `src/html_toc.zig` surface and execution

## Public API

### Constants

| Constant | Value | Purpose |
| --- | --- | --- |
| `toc_min_level` | `1` | Minimum heading level included in `&#123;&#123;toc&#125;&#125;` output |
| `toc_max_level` | `3` | Maximum heading level included in `&#123;&#123;toc&#125;&#125;` output (h1–h3 only) |
| `fragment_min_level` | `1` | Minimum level for wiki fragment target collection |
| `fragment_max_level` | `6` | Maximum level for wiki fragment target collection (h1–h6) |

### `Heading` struct

```

pub const Heading = struct {
level: u8,
id: []const u8,   // slice into caller's html; not owned
text: []const u8, // allocator-owned; caller must free
};

```

The dual ownership rule is the primary contract hazard: `id` is a zero-copy slice into the input buffer and must not outlive it; `text` is a fresh allocation and must be freed per entry. Misapplying `allocator.free(h.id)` would attempt to free a pointer into the middle of the HTML buffer.

### `collectHeadingsInRange`

Scans `html` for `<hN>` tags (N in `[min_level, max_level]`) with an `id` attribute, strips inner tags from the heading content, and appends `Heading` values to `out`. Returns `error.OutOfMemory` on allocation failure; partial results already appended to `out` remain valid and are the caller's responsibility.

### `collectHeadings`

Thin wrapper around `collectHeadingsInRange` with `toc_min_level`/`toc_max_level` (h1–h3).

### `collectHeadingIds`

Collects unique, non-empty heading IDs for h1–h6 (the full fragment set). Each returned `[]const u8` is a freshly allocated copy (not a slice into `html`), because the caller's use case (wiki-link resolution, heading-fragment index) may outlive the HTML buffer. Deduplication uses a `StringHashMapUnmanaged`. The comment in the source correctly notes that after `getOrPut`, the map's key pointer is re-seated to the owned copy to prevent the map from retaining a pointer into `html`.

### `renderToc`

High-level entry point: calls `collectHeadings`, then emits a `<nav class="page-toc" aria-label="On this page"><ul>…</ul></nav>` HTML fragment. Returns an empty owned string when no qualifying headings exist. The `li` elements use CSS class `page-toc__lN` where N is the heading level digit. Returns a caller-owned `[]u8`; caller must free. Uses `errdefer buf.deinit(allocator)` to clean up the output buffer on any error mid-render.

***

## Allocation and ownership analysis

The ownership model is the most important correctness property in this file.

**`Heading.id`** is always a slice into the caller-supplied `html` argument. It is never allocated. The caller must ensure the `html` buffer outlives any `Heading` values referencing it. Freeing `h.id` through the allocator is a bug; the test teardown loops (`for (list.items) |h| gpa.free(h.text)`) correctly free only `h.text`.

**`Heading.text`** is always allocator-owned. It is produced by `stripTags`, which either `dupe`s a trimmed slice (fast path, no `<` present) or builds an `ArrayList`, trims, and `dupe`s the result. In both cases the returned slice is fresh. On `out.append` failure inside `collectHeadingsInRange`, the code calls `allocator.free(text)` before returning the error — preventing a leak. The `checkAllAllocationFailures` test validates this at every injection point.

**`collectHeadingIds` output** contains fully owned copies (`allocator.dupe(u8, h.id)`). This is necessary because the upstream `collectHeadingsInRange` only produces `id` slices into `html`, and the wiki-fragment index may retain them past the HTML buffer's lifetime. The `StringHashMapUnmanaged` used for deduplication is also re-keyed to the owned copy (via `gop.key_ptr.* = owned`) to prevent the map's internal key storage from retaining a pointer into the HTML.

**`renderToc` output** is a single caller-owned `[]u8` produced by `buf.toOwnedSlice(allocator)`. The `buf` is protected by `errdefer buf.deinit(allocator)`, so any error during construction frees the partial buffer.

***
