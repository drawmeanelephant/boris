---
title: "`src/page.zig` surface and execution"
id: docs/boris/src/page/surface-and-execution
parent: docs/boris/src/page
status: draft
tags: [boris, zig, source-reference, surface, page]
---

# `src/page.zig` surface and execution

## Declared constants and their meaning

All bounds in this table are declared as the single source of truth, cross-referenced by `docs/contracts/frontmatter.md`:

| Constant | Value | Meaning |
| --- | --- | --- |
| `max_entity_id_bytes` | re-exported from `identity.zig` (255) | Maximum UTF-8 bytes for any entity id |
| `max_title_bytes` | 512 | Maximum UTF-8 bytes for a frontmatter `title` value |
| `max_tag_bytes` | 64 | Maximum UTF-8 bytes for one tag token after quote strip |
| `max_tag_count` | 32 | Maximum tags in one `tags: [...]` list |
| `max_source_bytes` | 1 048 576 (1 MiB) | Maximum source file size accepted by the parser |
| `max_frontmatter_bytes` | 65 536 (64 KiB) | Maximum bytes inside the frontmatter fences |
| `max_frontmatter_fields` | 32 | Maximum non-blank field lines in one frontmatter block |
| `max_relation_count` | 16 | Maximum semantic relations on one page in IR 0.3 grammar |

The constants are compiler-visible and can be imported by any module. Whether the parser actually enforces every bound at every path is a property of `src/parser.zig`, not of this file; the declaration here establishes the intended contract.

## Types

### `Status`

A closed Zig enum with three variants: `draft`, `published`, `archived`. The `parse` function performs exact-string matching (no case folding, no trimming). Any string that does not match one of the three exact spellings returns `null`. The `name` function delegates to `@tagName`. The closed vocabulary is tested directly in the file.

### `RelationKind`

A closed enum: `relates_to`, `implements`, `depends_on`, `supersedes`. The same exact-match `parse` pattern applies. Used in `SemanticRelation` structs stored on `DurablePage.relations` in IR 0.3 output.

### `SemanticRelation`

A plain struct pairing a `RelationKind` with a `target: []const u8` target entity-id slice. When stored on `FrontmatterView`, the `target` slice points into the source buffer. When stored on `DurablePage`, the `target` slice is retain-arena-owned (copied by `PageDb.promote`).

### `FrontmatterView`

A value type holding parsed frontmatter fields as slices into the caller's source buffer. All optional string fields (`id`, `title`, `parent`) default to `null`; `status` defaults to `null`. `tags` is a fixed array of `max_tag_count` slices, with `tag_count` tracking the valid prefix; `tagsSlice()` returns only the valid prefix. The same bounded-array pattern applies to `relations`/`relation_count`/`relationsSlice()`.

**Lifetime contract (documented, not mechanically enforced):** `FrontmatterView` must not outlive the source buffer passed to the parser. The type itself carries no borrow-checked lifetime. The structural separation from `DurablePage` is the sole mechanical guardrail. A caller that stores a `FrontmatterView` longer than its source buffer will produce dangling slice reads; this is undefined behavior in Zig.

### `Page`

The scan-time identity record for one discovered content file. All four string fields (`source_path`, `entity_id`, `output_path`) are documented as retain-owned from the moment `Page` is created by the scanner. `kind: ContentKind` is a closed enum re-exported from `identity.zig`. `Page` is designed to be stable and freely copyable after its strings are in the retain arena.

### `PageList`

A wrapper around `std.ArrayList(Page)` that holds two explicit allocators: `list_gpa` owns the `ArrayList` spine; `retain` owns every string on each `Page`. `deinit` calls `self.pages.deinit(self.list_gpa)` only — string memory is expected to be freed by releasing the arena passed as `retain`. The `pages` field is initialized with `.empty` (Zig's zero-allocation `ArrayList` sentinel), so `init` performs no allocation.

### `pageLessThan` and `sortPages`

`pageLessThan` defines the discovery determinism sort key: primary key is `entity_id` ascending (bytewise UTF-8), secondary key is `source_path` as a stable tiebreaker for duplicate entity ids (which are flagged as errors elsewhere but must sort deterministically to produce consistent diagnostics). `sortPages` is a thin wrapper calling `std.mem.sort`. Both are tested in the file.

### `Role`

A two-variant enum: `trunk` (no declared parent) and `satellite` (has a declared parent). Assigned during `PageDb.promote` based on the presence of `meta.parent`. May be updated by the graph module after relationship resolution; the graph fields are explicitly documented as "provisional until freeze."

### `DurablePage`

The long-lived per-page record. Every string field is retain-arena-owned. The graph fields (`role`, `index`, `parent_index`) have zero-value defaults (`trunk`, `0`, `null`) that are meaningful only after graph processing. The `body_offset: usize` is a byte count into the source file (not a live pointer or slice), so it remains valid after the source buffer is freed. Tag and relation slices are retain-owned via `PageDb.promote`.

### `PageDb`

The session-scoped page database. Mirrors `PageList`'s dual-allocator design. Key methods:

- `dupe(s)` / `dupeOpt(s)`: copy a string into the retain arena; `dupeOpt` propagates `null`.
- `itemsMut()`: returns a mutable slice, used by the graph module to write graph fields after the build phase.
- `promote(discovery, entity_id, meta, body_offset)`: the central ownership-crossing function.

#### `PageDb.promote` in detail

`promote` performs the following steps in order:

1. Copy each tag string from `meta.tagsSlice()` into the retain arena, allocating a `[]const []const u8` slice also on the retain arena.
2. Copy each `SemanticRelation` target string into the retain arena, allocating a `[]const SemanticRelation` slice also on the retain arena.
3. Determine the final `output_path`: if the final `entity_id` equals `discovery.entity_id` (no override), copy `discovery.output_path` onto the retain arena; otherwise recompute via `identity.safeOutputRelativePath` (which validates the entity id and cannot escape the output root).
4. Copy `entity_id`, `source_path`, `output_path` onto the retain arena via `self.retain.dupe`.
5. Set `role` to `.satellite` when `meta.parent != null`, `.trunk` otherwise.
6. Append the assembled `DurablePage` to `self.pages`.

If any allocation fails, `promote` returns an error and the `DurablePage` is not appended (atomicity within a single call, not transactional across the session).

## Ownership boundary analysis

### Structural separation of transient and durable

The most significant design property in this file is the two-level type split. `FrontmatterView` can only be constructed by the parser (or manually in tests) and holds no allocator reference; it cannot copy itself to longer-lived storage. `DurablePage` holds no reference to a source buffer. The only bridge is `PageDb.promote`. This means a correct pipeline cannot accidentally assign a parser slice to a durable field without going through `promote`; but it also means a pipeline that constructs a `DurablePage` literal manually (e.g. in tests) is fully responsible for ensuring string lifetimes.

### What `PageDb.promote` does and does not guarantee

`promote` is structurally correct: it always calls `self.retain.dupe` or `self.retain.alloc` for every string-bearing field, and it uses `errdefer` implicitly through Zig's error return (allocations that fail do not partially populate the page). However, there is no compile-time enforcement that the caller passes a `FrontmatterView` whose slices truly point into a source buffer (versus, say, a string literal or another arena). The guarantee is therefore: **assuming `promote` is called correctly, no dangling reference will be retained.** The `PageDb.promote owns strings after source buffer free` test directly demonstrates this property under the standard allocator with a deliberately freed temporary buffer.

### Tags and relations slice allocation

When `tags_src.len > 0`, `promote` allocates a `[]const []const u8` slice on the retain arena and copies each tag string. When zero, it assigns `&.{}` (an empty slice with no allocation). The same pattern applies to `relations`. This means a `DurablePage` with zero tags incurs no allocation for that field, and the resulting slice is a safe empty slice (not a dangling pointer). The `tags[i]` indexing during the copy loop uses `for (tags_src, 0..)`, which is bounds-safe for the populated range.

### `body_offset` is not a pointer

`body_offset: usize` stores a byte count (the parser's reported start of body content in the source file). It is not a slice, not a pointer, and does not become dangling when the source buffer is freed. It is safe to store in `DurablePage` by value.

### `itemsMut` and graph freeze

`PageDb.itemsMut()` returns a `[]DurablePage`, allowing the graph module to write `role`, `index`, and `parent_index` after relationship resolution. The file documents these fields as "provisional until freeze; stable after freeze," but there is no Zig mechanism (e.g., a frozen flag) enforcing the freeze contract. Any code that reads graph fields before the graph phase completes will see zero-value defaults. This is a documented caller obligation, not a mechanically enforced invariant.
