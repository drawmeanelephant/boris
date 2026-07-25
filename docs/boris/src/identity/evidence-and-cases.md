---
title: "`src/identity.zig` evidence and cases"
id: docs/boris/src/identity/evidence-and-cases
parent: docs/boris/src/identity
status: draft
tags: [boris, zig, source-reference, evidence, identity]
---

# `src/identity.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `relativeHref same dir one level up and root to nested` | `test` | Verifies all four relative-href generation cases | Five `relativeHref` calls with varying depth | `b.html`, `../index.html`, `guides/intro.html`, `../../x/y.html`, `intro.html` | Output hrefs never use absolute paths; `../` count equals depth delta |
| `canonicalize basic and nested` | `test` | Happy path for one- and two-level paths | `guides/intro.md`, `nested/deep/page.md` | Byte-identical strings returned | Canonical form rule 2 (only `/` separators) and rule 3 (no leading `./`) |
| `canonicalize rejects absolute empty and dot components` | `test` | Rejection of 8 distinct pathological inputs | Empty string, `../x.md`, `a/../b.md`, `a//b.md`, `a/./b.md`, `a/b/`, `/abs.md`, `C:\abs.md`, `c:/abs.md` | Exact error codes: `EmptyPath`, `IllegalSegment` (×5), `AbsolutePath` (×3) | Rules 1–4 of source path canonical form |
| `canonicalize normalizes backslash and leading dot-slash` | `test` | Single-step normalization combining two transformations | `./guides\intro.md` | `guides/intro.md` | Leading `./` strip + backslash-to-slash normalization |
| `isPageFile extension policy is case-sensitive lowercase only` | `test` | Exhaustive extension-policy matrix | 13 inputs covering true/false cases for all three extensions in multiple cases | Exact bool per input | Extension policy (case-sensitive, lowercase only) |
| `canonicalEntityId is the single derivation path` | `test` | Happy path covering 8 inputs including case preservation, `.mdx`, `.textile`, backslash, dots-in-stem | 8 calls with varied paths | Exact id string per input | Single-derivation rule; case preservation; extension variants |
| `canonicalEntityId rejects traversal non-page and empty stem` | `test` | Rejection of traversal, wrong extension, empty stem | `../escape.md`, `a/../b.md`, `/abs.md`, `notes.txt`, `notes.MD`, `.md`, `.mdx`, `.textile` | `IllegalSegment`, `AbsolutePath`, `UnsupportedExtension` (×2), `EmptyId` (×3) | Traversal block; extension case-sensitivity; no empty id |
| `InputFormat admits one explicit source family` | `test` | Exhaustive cross-product of `InputFormat × ContentKind` | 6 `accepts` calls | Exact bool: markdown accepts md/mdx not textile; textile accepts textile only | `InputFormat` isolation rule |
| `canonicalEntityId rejects oversize stem` | `test` | Upper-bound enforcement at exactly 256 bytes | Constructs a 259-byte input (`z` × 256 + `.md`) | `error.IdTooLong` | `max_entity_id_bytes = 255` |
| `safeOutputRelativePath never escapes via bad entity ids` | `test` | Output path safety for valid and adversarial ids | 2 valid ids; 5 adversarial: `../etc/passwd`, `a/../../x`, `/abs`, `a\b`, empty | `.html` suffix on valid; `IllegalSegment`, `AbsolutePath`, `EmptyId` on bad | Output-root confinement |
| `validateEntityId shape` | `test` | Shape validator for 11 inputs | Mix of valid (`guides/intro`, `Guides/Intro`, `my.notes`) and invalid (empty, leading `/`, backslash, `//`, `..`, `.`, trailing `/`, whitespace) | Exact bool per input | `validateEntityId` predicate completeness |

## Key function walkthroughs

### `canonicalize`

`canonicalize` is a single-pass byte scanner over the raw input. After rejecting leading `/` and Windows drive prefixes (`X:`) and stripping a single leading `./` or `.\`, it enters a loop that reads one segment at a time (delimited by `/` or `\`). Any separator character encountered at the start of a segment (signifying an empty segment, double-slash, or trailing slash) immediately returns `error.IllegalSegment`. After collecting a segment, it checks for `.` and `..` by exact equality and rejects both. Accepted segments are appended to an `std.ArrayList(u8)` with a `/` prefix on all but the first. Trailing slash detection works by a sentinel check: after consuming a separator, if `i >= raw.len` the trailing slash has been seen and the function returns `error.IllegalSegment`.

The allocation strategy is `errdefer buf.deinit(allocator)`, so on any error path the partial buffer is freed before returning the error. On success, `toOwnedSlice` transfers ownership to the caller. The returned slice uses only `/` separators and has no leading or trailing separator.

**Note:** The backslash handling in `canonicalize` is indirect. `isSep` treats `\` as a separator, meaning `guides\intro.md` is parsed as two segments (`guides`, `intro.md`) separated by `\`, and the output uses `/`. However, a leading `\` is rejected as `AbsolutePath` (via `isSep(raw[^1_0])`), and a Windows drive prefix (`C:\`) is rejected as `AbsolutePath`. The test `canonicalize normalizes backslash and leading dot-slash` demonstrates `./guides\intro.md` → `guides/intro.md`, directly confirming this.

### `canonicalEntityId`

This is the documented single entry point for graph key derivation. Its pipeline is:

```text
raw source path (platform separators OK)
    → canonicalize(allocator, raw)          -- allocates; deferred free
    → stemFromSourcePath(canon)             -- slice into canon; no allocation
    → length check against max_entity_id_bytes
    → validateEntityId(stem)
    → allocator.dupe(u8, stem)              -- final allocation; caller owns
```

The intermediate `canon` allocation is freed via `defer allocator.free(canon)` immediately after `stem` is extracted (since `stem` is a sub-slice of `canon`, this defer executes after `stem` is used but before the `dupe` result is returned). The final returned slice is an independent allocation with no lifetime dependency on `canon`. This is structurally sound: `dupe` copies before `canon` is freed.

**Potential concern (structural, not a demonstrated defect):** `validateEntityId` is called on `stem`, which is a sub-slice of `canon`. `validateEntityId` rejects backslash (`\\`), but `canonicalize` already normalizes all `\` to `/` in its output. The double-check is therefore redundant but harmless. If `canonicalize` ever acquired a code path that preserved `\` in output, `validateEntityId` would catch it.

### `safeOutputRelativePath` and `ragPagePath`

Both functions call `validateEntityId(entity_id)` before doing any allocation. On validation failure they perform a three-way disambiguation—empty → `EmptyId`, oversize → `IdTooLong`, leading `/` or `\` → `AbsolutePath`, otherwise → `IllegalSegment`—to return a precise error code. This re-validation means callers can pass entity ids from any source and still receive a structural guarantee, but it also means callers who construct ids through means other than `canonicalEntityId` are only one validation call away from a potential bug if the id arrives unvalidated.

### `relativeHref`

`relativeHref` splits both `from_output` and `to_output` directory components using `std.fs.path.dirnamePosix` (which returns an optional—null for root-level files) and a private `splitPathComponents` helper. It computes the common prefix length, counts `up` steps, then builds the output string in a single allocation sized exactly for the result. A `std.debug.assert(off == total)` guards the final byte count.

**Capacity limit:** `splitPathComponents` accepts an output slice of size 32 and truncates defensively if more than 32 components are present. Paths with directory depth > 32 will produce silently incorrect relative hrefs without returning an error. This is not tested.

## Control flow

```text
[caller: scanner.zig]
    → canonicalEntityId(allocator, raw_source_path)
        → canonicalize(allocator, raw_source_path)
            → reject absolute / drive prefix
            → strip leading "./"
            → loop: reject empty/./.. segments, normalize \ to /
            → toOwnedSlice → canon  [heap]
        → stemFromSourcePath(canon)
            → pageExtensionLen(canon) → ext_len or UnsupportedExtension
            → slice canon[0..len-ext_len] → stem  [sub-slice, no alloc]
        → length check: stem.len > 255 → IdTooLong
        → validateEntityId(stem)
            → reject leading /, trailing /, \\, //, ./.. segments, whitespace
            → false → IllegalSegment
        → allocator.dupe(stem) → id  [heap; caller owns]
        → defer allocator.free(canon)  [fires here]
        → return id

[caller: rag.zig / pipeline.zig]
    → ragPagePath / safeOutputRelativePath(allocator, entity_id)
        → validateEntityId(entity_id)
            → false → categorized error
        → std.fmt.allocPrint → output_path  [heap; caller owns]
        → return output_path
```
