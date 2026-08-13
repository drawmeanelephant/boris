---
title: "`src/identity.zig` surface and execution"
id: docs/boris/src/identity/surface-and-execution
parent: docs/boris/src/identity
status: draft
tags: [boris, zig, source-reference, surface, identity]
---

# `src/identity.zig` surface and execution

## Exported API surface

The module exports the following public declarations:

### Constants and error types

| Name | Kind | Description |
| --- | --- | --- |
| `max_entity_id_bytes` | `pub const usize = 255` | Hard upper bound on entity id length in UTF-8 bytes |
| `PathError` | `pub const error{...}` | Union of path-specific errors plus `std.mem.Allocator.Error`; variants: `EmptyPath`, `AbsolutePath`, `IllegalSegment`, `EmptyId`, `UnsupportedExtension`, `IdTooLong` |
| `InputFormat` | `pub const enum` | `markdown` or `textile`; carries `accepts(ContentKind) bool` |
| `ContentKind` | `pub const enum` | `md`, `mdx`, `textile`; carries `extension() []const u8` |

### Functions

| Function | Signature | Allocates | Returns | Purpose |
| --- | --- | --- | --- | --- |
| `isPageFile` | `([]const u8) bool` | No | bool | Case-sensitive check for `.md`, `.mdx`, `.textile` suffix |
| `pageExtensionLen` | `([]const u8) ?usize` | No | optional usize | Returns byte length of recognized trailing extension, or null |
| `contentKind` | `([]const u8) PathError!ContentKind` | No | ContentKind or error | Maps extension to enum variant; error on unrecognized |
| `canonicalize` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | normalized path or error | Reject absolute/dot/empty/backslash; normalize separators |
| `validateEntityId` | `([]const u8) bool` | No | bool | Structural check on an already-produced id |
| `stemFromSourcePath` | `([]const u8) PathError![]const u8` | No (slice into input) | sub-slice or error | Strip trailing page extension; return slice into argument |
| `normalizeEntityId` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | normalized id or error | Replace `\` with `/`, validate shape |
| `canonicalEntityId` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | canonical id or error | **Single entry point for graph key derivation** |
| `safeOutputRelativePath` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | `{id}.html` or error | Produce HTML-relative output path; re-validates entity id |
| `htmlOutputPath` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | delegates to above | Historical alias for `safeOutputRelativePath` |
| `ragPagePath` | `(Allocator, []const u8) PathError![]u8` | Yes (caller owns) | `content/pages/{id}.md` | RAG corpus path; re-validates entity id |
| `pathsDifferOnlyInCase` | `([]const u8, []const u8) bool` | No | bool | True when two paths are ASCII-case-equivalent but not byte-equal |
| `relativeHref` | `(Allocator, []const u8, []const u8) ![]u8` | Yes (caller owns) | relative href string | Construct `../`-relative inter-page link from two output-relative paths |

`splitPathComponents` is a private helper used only by `relativeHref`; it is not exported.

## Contract alignment

The normative contract is `docs/contracts/identity-and-paths.md`. The following table maps each contract rule to evidence of implementation:

| Contract rule | Implementation location | Evidence strength |
| --- | --- | --- |
| Single derivation function: `canonicalEntityId` only | `canonicalEntityId` is the only allocating id-derivation path; `normalizeEntityId` exists but is not called by scanners in isolation (uncertain at call sites) | Structurally checked within this file; contract-only for call-site enforcement |
| Case-sensitive extensions: `.md`, `.mdx`, `.textile` only | `isPageFile`, `pageExtensionLen`, `contentKind` use `std.mem.endsWith` with literal strings | Directly demonstrated by `isPageFile extension policy is case-sensitive` test |
| Letter case preserved, never lowercased | No `std.ascii.toLower` or `std.unicode` normalization call in any id-producing path | Structurally checked; demonstrated by `canonicalEntityId` test with `Guides/Intro.md` → `Guides/Intro` |
| Entity id ≤ 255 UTF-8 bytes | `max_entity_id_bytes = 255`; checked in `canonicalEntityId` via `stemFromSourcePath` length check, and in `validateEntityId` | Directly demonstrated by `canonicalEntityId rejects oversize stem` test |
| Entity id never starts with `/`, never contains `\`, no empty/`.`/`..` segments | `validateEntityId` enforces all; called from `canonicalEntityId` and both output-path functions | Directly demonstrated by `validateEntityId shape` and `safeOutputRelativePath` tests |
| Output paths only from validated ids (cannot escape root) | `safeOutputRelativePath` and `ragPagePath` call `validateEntityId` before `std.fmt.allocPrint` | Directly demonstrated by `safeOutputRelativePath never escapes` test |
| Frontmatter `id:` override satisfies same shape rules | `validateEntityId` is the shared validation predicate; upstream caller responsible for invoking it | Contract-only; no test in this file exercises frontmatter override path |
| `.textile` accepted only in explicit textile mode | `InputFormat.textile.accepts(.textile)` and `.markdown.accepts(.textile) == false` | Directly demonstrated by `InputFormat admits one explicit source family` test |

## Allocation ownership summary

| Function | Who allocates | Who frees | Notes |
| :-- | :-- | :-- | :-- |
| `canonicalize` | callee | caller | `errdefer buf.deinit` on error |
| `normalizeEntityId` | callee | caller | `errdefer allocator.free(out)` on error |
| `canonicalEntityId` | callee (twice: `canon` + `dupe`) | `canon` freed internally via `defer`; returned slice freed by caller | Intermediate `canon` freed before return |
| `safeOutputRelativePath` | callee via `std.fmt.allocPrint` | caller | `errdefer allocator.free` on format error |
| `ragPagePath` | callee via `std.fmt.allocPrint` | caller | same |
| `relativeHref` | callee | caller | `errdefer allocator.free(out)` on error |
| `stemFromSourcePath` | none (slice into argument) | n/a | Returned slice lifetime ≤ argument lifetime |
| `htmlOutputPath` | delegates entirely to `safeOutputRelativePath` | caller |  |

All allocating functions use `errdefer` or `defer` correctly to avoid leaking partial allocations on error paths. This is structurally confirmed by code inspection; leak-freedom under all error conditions is not independently verified by a sanitizer run within the `zig build test` path.
