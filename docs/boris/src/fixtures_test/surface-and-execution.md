---
title: "`src/fixtures_test.zig` surface and execution"
id: docs/boris/src/fixtures_test/surface-and-execution
parent: docs/boris/src/fixtures_test
status: draft
tags: [boris, zig, source-reference, surface, fixtures_test]
---

# `src/fixtures_test.zig` surface and execution

## Public API

This module exports **no** product API. Everything is file-private helpers plus `test` blocks.

### Private constants

```zig
const required_categories = [_][]const u8{
    "EDUPLICATEID",
    "EPARENTMISSING",
    "EPARENTSELF",
    "EPARENTNOTTRUNK",
    "EPARENTCYCLE",
    "EFRONTMATTER",
    "EINVALIDUTF8",
    "EINVALIDPATH",
};
```

These strings are the content-error subset that the inventory must document. The comment ties them to `docs/contracts/diagnostics.md`.[^3_1]

### Private helpers

| Symbol | Signature (conceptual) | Role |
| :-- | :-- | :-- |
| `readFileAlloc` | `(io, dir, path, allocator) ![]u8` | Open relative path under `dir`, read full contents with unlimited alloc |
| `pathExists` | `(io, dir, rel) bool` | `access` success → true; any error → false |
| `openFixtures` | `(io) !Io.Dir` | `cwd.openDir(io, "fixtures", .{})`; on failure logs that tests must run with cwd at package root |

No types, errors, or functions are `pub` for other modules to import as a library.[^3_1]

***

## Manifest contract (as assumed by this file)

The tests treat `fixtures/manifest.json` as JSON with at least:

- **`valid`**: array of objects with string field **`path`** (relative to `fixtures/`). Length must be **4**.
- **`invalid`**: array of objects with:
    - **`expectedCategory`**: string diagnostic code
    - **`paths`**: array of strings; each entry must have **exactly one** path
Length must equal **`required_categories.len`** (8).
- **`requiredInvalidCategories`**: array of strings; every element must appear as some invalid entry’s `expectedCategory`.

The file does not validate JSON schema beyond these field accesses (`get(...).?` will panic/fail if structure is wrong). Extra fields are ignored.[^3_1]

***

## Allocation and ownership

| Object | Allocated by | Freed by |
| :-- | :-- | :-- |
| File body from `readFileAlloc` | `allocator` (tests use `std.testing.allocator`) | `defer allocator.free(raw)` in each test |
| `std.json.parseFromSlice` parse tree | testing allocator | `defer parsed.deinit` |
| `seen_categories` / `found` hash maps | testing allocator | `defer map.deinit(allocator)` |
| `Io.Dir` from `openFixtures` | OS handle | `defer fixtures.close(io)` |

No module-level state, no arenas retained across tests, no production allocator.[^3_1]

***

## What the module cannot validate

1. **That invalid fixtures emit the claimed codes under the real compiler**
Inventory only. Graph/parser diagnostics are exercised elsewhere (`docs/contracts/fixtures`, pipeline/hardening tests).[^3_1]
2. **That all files under `fixtures/content/**` appear in the manifest**
Only paths listed in `valid` / `invalid` are checked. Orphan files on disk are invisible to these tests.
3. **That `valid` entries are actually parse/graph-valid**
Presence only; no `parser.parse` or `pipeline.compile` call.[^3_1]
4. **Cross-tree parity with `docs/contracts/fixtures`**
No comparison between root `fixtures/` and contract fixtures.
5. **Windows / non-root cwd**
Failure mode is “cannot open `fixtures`” with a log hint; there is no alternate path resolution via `build.zig` install paths in this file.[^3_1]
6. **Category code spelling vs live `diag.Code` / `Category` enums**
Strings are compared to hard-coded lists and manifest text, not to Zig enums via `@tagName`.

***

## Relationship to other fixture consumers

| Consumer | Fixture root | Runs compiler? |
| :-- | :-- | :-- |
| `src/fixtures_test.zig` | `fixtures/` | No |
| `src/parser.zig` fixture-driven tests | `fixtures/content/...` (read helpers) | Parser only on file bytes |
| Pipeline / CLI / hardening tests | Often `docs/contracts/fixtures/...` | Yes |
| Release gate | Contract fixtures + scripts | Yes |

`parser.zig` reuses some of the same root `fixtures/content/valid` and `invalid` paths for category checks; that is complementary, not a substitute for this inventory module.[^3_1]

***
