---
title: "`src/frontmatter.zig` surface and execution"
id: docs/boris/src/frontmatter/surface-and-execution
parent: docs/boris/src/frontmatter
status: draft
tags: [boris, zig, source-reference, surface, frontmatter]
---

# `src/frontmatter.zig` surface and execution

## Threat model

The threat model for `frontmatter.zig` is the content-author threat surface: adversarial or malformed Markdown files that could inflate the retain arena, smuggle invalid IDs into the graph, crash the parser, or produce misleading metadata. The file addresses the following categories directly:

**Encoding attacks**
- UTF-8 BOM (`0xEF 0xBB 0xBF`) at file start: detected before fence parsing, emits `EINVALIDUTF8`, returns immediately.
- Invalid UTF-8 byte sequences: detected via `std.unicode.utf8ValidateSlice`, same handling.

**Fence / structural malformation**
- Missing opening `---` fence: treated as body-only document, `has_frontmatter` stays false, no diagnostic.
- `---` followed by non-newline content on the same line (e.g. `--- title: x`): emits `EFRONTMATTER`, returns immediately.
- Unclosed frontmatter (no closing `---` before EOF): detected at EOF, emits `EFRONTMATTER`, sets `body_offset` to end-of-source.
- CRLF line endings: explicitly handled (`\r` stripped from each line before processing).

**Key-level attacks**
- Unknown / unsupported keys: emit `EFRONTMATTER` with the key name in the message, parsing continues (does not abort).
- Duplicate keys (e.g. two `title:` lines): first value wins, second emits `EFRONTMATTER`.
- Empty key (`:` with no key text): emits `EFRONTMATTER`.
- Lines without `:`: emit `EFRONTMATTER` as "malformed frontmatter line".

**Value-level attacks**
- YAML block scalars (`|`, `>`), flow collections (`[`, `{` except in tags), anchors/aliases (`&`, `*`): rejected by `parsePlainOrQuoted`.
- Single-quoted strings (`'`): rejected explicitly.
- Empty values: rejected as `error.EmptyValue`.
- Malformed double-quoted strings (unclosed, or embedded `"`): rejected as `error.BadQuote`.

**Size attacks (arena protection)**
- `title` exceeding `max_title_bytes` (512): emits `EFRONTMATTER` with the actual byte count, value is **not** copied into the retain arena (`meta.title` remains null). Verified by test including an arena-capacity check.
- `id` exceeding `max_entity_id_bytes` (255): same rejection-before-dupe pattern.
- `parent` exceeding `max_entity_id_bytes`: same pattern.

**Identity / graph integrity**
- `id` that fails `validateEntityId` (empty segments, `..`, whitespace, backslash, leading `/`, oversize): emits `EFRONTMATTER`, `meta.id` stays null.
- `parent` that fails `validateEntityId`: same.

**Tag-list attacks**
- Non-bracket tag value (e.g. `tags: nope`): `parseTagsList` returns `error.BadTags`, emits `EFRONTMATTER`, `meta.tags` stays empty.
- Trailing comma in tag list (`[alpha, \t]`): detected because after a comma the remaining trimmed content is empty, returns `error.BadTags`.
- YAML-looking tag items (block, flow, anchor within a tag token): caught by per-item `parsePlainOrQuoted` call.

**Untested / uncertain categories**
- Maximum tag count (`max_tag_count = 32` from `page.zig`) is *not* enforced by `frontmatter.zig`. A document with 33 tags will have all 33 returned in the `ArrayList`-backed slice. The contract exists in `page.zig` but is not a validation gate here.
- Maximum tag token length (`max_tag_bytes = 64`) is likewise not enforced.
- Maximum frontmatter block size (`max_frontmatter_bytes = 64 KiB`) is not checked; a very large frontmatter block will be processed line by line without a byte cap.
- Maximum field count (`max_frontmatter_fields = 32`) is not enforced.
- Concurrent access: not applicable by structure, but not demonstrated by test.

***

## Allocator ownership model

`parse` takes two allocators with distinct roles:

- **`retain`** (caller's long-lived arena): owns all string data stored in `Meta` — `id`, `title`, `parent`, tag strings, and the tag slice itself. Also owns small diagnostic message strings (formatted via `std.fmt.allocPrint`). Never receives oversized values.
- **`list_gpa`** (typically a GPA or other non-arena allocator): owns the `diags.items` array spine (the `ArrayList` backing store). Strings *within* each `Diagnostic` are owned by `retain`, not by `list_gpa`.

`source_path` is passed as a `[]const u8` that is stored verbatim in each `Diagnostic.source_path`. The contract comment states it "must outlive diags" — this is a caller obligation not mechanically enforced.

`parseTagsList` uses its own `ArrayList([]const u8)` backed by `retain` internally, then calls `toOwnedSlice(retain)` to return a `retain`-owned slice. Individual tag strings are also `retain.dupe`d. The `errdefer list.deinit(retain)` in `parseTagsList` is a correctness concern: for arena allocators, `deinit` is a no-op (arenas free everything at once), but for non-arena allocators passed as `retain`, partial tag-list allocation on parse failure would leak the partially-built list if the allocator is not an arena. In production Boris usage, `retain` is always an arena, so this is safe in practice but not guaranteed by the function signature.

***

## Key constants and their sources

| Constant | Value | Declared in | Imported via |
| :-- | :-- | :-- | :-- |
| `max_title_bytes` | `512` | `src/page.zig` | `page_mod.max_title_bytes` |
| `max_entity_id_bytes` | `255` | `src/identity.zig` | `page_mod.max_entity_id_bytes` → `identity.max_entity_id_bytes` |
| `max_tag_bytes` | `64` | `src/page.zig` | **Not imported or enforced in this file** |
| `max_tag_count` | `32` | `src/page.zig` | **Not imported or enforced in this file** |
| `max_frontmatter_bytes` | `65536` | `src/page.zig` | **Not imported or enforced in this file** |


***

## Structural redundancy

`frontmatter.zig` declares its own `pub const Status` enum with `parse` and `name` methods that are byte-for-byte identical to `page.zig`'s `Status`. It also re-exports `max_title_bytes` and `max_entity_id_bytes` from `page_mod`. The duplication of `Status` means that callers of `frontmatter.parse` receive a `Meta.status` typed as `frontmatter.Status`, which is a *different* type than `page.Status` even though both have the same three variants. Any code that receives a `frontmatter.Meta` and tries to assign `meta.status` to a `page.FrontmatterView.status` field (which is typed `?page.Status`) must convert between the two, or the compiler will reject the assignment. This is a latent integration friction point, not a correctness defect — Zig's structural typing means the enum values are not interchangeable by identity without an explicit conversion.

***
