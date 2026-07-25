---
title: "`src/pathutil.zig` surface and execution"
id: docs/boris/src/pathutil/surface-and-execution
parent: docs/boris/src/pathutil
status: draft
tags: [boris, zig, source-reference, surface, pathutil]
---

# `src/pathutil.zig` surface and execution

## Exported symbol inventory

The file exports the following symbols, all delegated directly to `identity.zig`:

| `pathutil` export name | Delegates to `identity` symbol | Notes |
| --- | --- | --- |
| `max_entity_id_bytes` | `identity.max_entity_id_bytes` | Constant: `255` |
| `PathError` | `identity.PathError` | Error union type |
| `ContentKind` | `identity.ContentKind` | Enum: `.md`, `.mdx`, `.textile` |
| `isPageFile` | `identity.isPageFile` | Case-sensitive extension check |
| `isMarkdownFile` | `identity.isPageFile` | **Alias** — identical target, historical name |
| `pageExtensionLen` | `identity.pageExtensionLen` | Returns `?usize` |
| `contentKind` | `identity.contentKind` | Returns `PathError!ContentKind` |
| `canonicalize` | `identity.canonicalize` | Allocating; caller owns result |
| `validateEntityId` | `identity.validateEntityId` | Pure predicate; no allocation |
| `stemFromSourcePath` | `identity.stemFromSourcePath` | Slice into caller's input; no allocation |
| `normalizeEntityId` | `identity.normalizeEntityId` | Allocating; caller owns result |
| `canonicalEntityId` | `identity.canonicalEntityId` | **Canonical entry point** per module contract |
| `entityIdFromSource` | `identity.canonicalEntityId` | **Alias** — historical name |
| `idFromSourcePath` | `identity.stemFromSourcePath` | **Alias** — historical name |
| `safeOutputRelativePath` | `identity.safeOutputRelativePath` | Allocating; caller owns result |
| `htmlOutputPath` | `identity.htmlOutputPath` | Alias for `safeOutputRelativePath` in `identity.zig` |
| `ragPagePath` | `identity.ragPagePath` | Allocating; caller owns result |
| `pathsDifferOnlyInCase` | `identity.pathsDifferOnlyInCase` | Pure predicate; no allocation |
| `relativeHref` | `identity.relativeHref` | Allocating; caller owns result |

The three notable aliased pairs are:
- `isMarkdownFile` → `isPageFile`: the historical name implied the function only handled Markdown; the current implementation accepts `.md`, `.mdx`, and `.textile`, so the new name is more accurate.
- `entityIdFromSource` → `canonicalEntityId`: rename aligned with the canonical single-entry-point convention.
- `idFromSourcePath` → `stemFromSourcePath`: rename clarified that the function strips the extension and returns a stem slice (not a full entity ID derivation).

***

## Semantic contracts inherited via re-export

Because `pathutil.zig` re-exports `identity.zig` symbols without wrapping, all contracts documented for `identity.zig` apply identically when called through `pathutil`. Key properties established by the `identity.zig` implementation (verified by its inline tests):

- **Allocation ownership:** Functions that allocate (`canonicalize`, `normalizeEntityId`, `canonicalEntityId`, `safeOutputRelativePath`, `htmlOutputPath`, `ragPagePath`, `relativeHref`) return caller-owned slices. The caller is responsible for `free`-ing them. The implementations use the passed `std.mem.Allocator` directly; there is no hidden arena.
- **Zero-allocation paths:** `isPageFile`, `pageExtensionLen`, `validateEntityId`, `pathsDifferOnlyInCase` perform no allocation. `stemFromSourcePath` returns a sub-slice of its input with no allocation.
- **Case sensitivity:** Extension matching is case-sensitive lowercase. `.MD`, `.Md`, `.MDX` are rejected by `isPageFile` and `contentKind`. This is structurally verified by the `isPageFile extension policy is case-sensitive lowercase only` test in `identity.zig`.
- **Path traversal prevention:** `canonicalize` and `canonicalEntityId` reject `..` segments, empty segments, absolute paths, and Windows drive prefixes. `safeOutputRelativePath` re-validates the entity ID before constructing output paths. These properties are structurally checked by the inline tests in `identity.zig`.
- **Max ID length:** `max_entity_id_bytes = 255`. `canonicalEntityId` returns `error.IdTooLong` for stems exceeding this. Verified by the `canonicalEntityId rejects oversize stem` test.
- **Letter case preservation:** Entity IDs preserve the letter case of the source path stem. There is no case folding.

None of the above properties are re-tested or independently asserted within `pathutil.zig` itself.

***

## Migration status and deprecation signal

The module-level doc comment in `pathutil.zig` constitutes an in-source deprecation notice. It states:

> **Canonical implementation lives in `identity.zig`.** New code must import `identity` and use `identity.canonicalEntityId` as the single derivation entry. This module exists so experimental stages still compile against the historical import path.

The phrase "experimental stages" suggests that the legacy call sites retaining the `pathutil` import path are expected to be experimental or transitional pipeline stages, not stable production modules. No mechanism in the Zig compiler or build system enforces this guidance; any module, including production code, can import `pathutil.zig` freely without warning.

A GitHub code search for `pathutil` across the repository returned zero results beyond the file itself, suggesting that either (a) no current in-tree module imports `pathutil.zig` by that name, or (b) call sites reference it under a local alias that does not appear in source as the literal string `pathutil`. This search result is **uncertain** because the code search index may not cover all branches or may have incomplete coverage at time of query.

If no in-tree module currently imports `pathutil.zig`, the file may be a candidate for removal. That determination requires a confirmed audit of all `@import` call sites in the repository.

***
