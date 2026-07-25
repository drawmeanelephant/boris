---
title: "`src/theme.zig` evidence and cases"
id: docs/boris/src/theme/evidence-and-cases
parent: docs/boris/src/theme
status: draft
tags: [boris, zig, source-reference, evidence, theme]
---

# `src/theme.zig` evidence and cases

## Test harness construction

All tests in `src/theme.zig` are `test` blocks embedded in the same file as the production code. They are compiled and executed as part of the standard `zig build test` step. There is no separate test root, no mock allocator, no hostile C implementation, and no ABI boundary.

Each integration test that requires filesystem access creates a unique working directory under `.zig-cache/tmp/<tmp.sub_path>/boris-theme-<name>` using `std.testing.tmpDir(.{})`, then calls `defer tmp.cleanup()` to remove it after the test. `std.testing.allocator` is used for all heap allocation, which enables leak detection.

`src/assemble.zig` is imported at the top of `theme.zig` as `const assemble = @import("assemble.zig");`. Its `LayoutError` union and `validateAssetUrlPath` function are used directly. No build options alter behavior of the theme module. No external libraries beyond the Zig standard library and `assemble.zig` are linked.

`std.Io` and `Io.Dir` are the I/O abstractions used throughout; `std.testing.io` and `Io.Dir.cwd()` are used in tests. These are Zig 0.16 abstractions; the file assumes the Zig version in use supports `Dir.walkSelectively`, `Dir.statFile` with `follow_symlinks` option, `Dir.createFileAtomic`, and `File.Atomic.replace`.

The production binary includes this module. The test binary also includes it. There is no separate "hostile" compilation path.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `themeRootFromLayoutPath` | `pub fn` | Derive theme root prefix from a layout path ending in `.../layouts/<file>.html` | Various path strings | Slice view into input, or `null` for legacy/bare paths | Zero-allocation slice view; null for legacy layout paths without a named theme root |
| `validateThemeRootPath` | `pub fn` | Reject path-escaping theme root strings | Path strings with `/`, `\\`, `C:`, `..`, `.`, empty segments | `error.InvalidThemePath` or success | Path grammar; no allocations |
| `loadThemeBundle` | `pub fn` | Load footer + asset inventory from a theme root directory | Real tmp dir with CSS, footer, optional symlinks | `ThemeBundle` with sorted assets and footer bytes, or appropriate error | Symlink rejection, UTF-8 gating, asset path validation, errdefer cleanup |
| `ThemeBundle.deinit` | method | Free all owned memory | `ThemeBundle` with assets and footer | No leaks (verified by `std.testing.allocator`) | Ownership — all `gpa.free` calls match `gpa.alloc` |
| `requireReferencedAssets` | `pub fn` | Assert all referenced asset paths exist in the bundle | Bundle + path list | `error.AssetNotFound` when a path is absent | Layout-to-inventory reference integrity |
| `checkAssetPageCollisions` | `pub fn` | Fail if any asset path equals a page output path | Asset slice + page output slice | `error.AssetCollision` on match | Output namespace disjointness |
| `copyAssetsToOutput` | `pub fn` | Write inventoried assets into `out_dir` | `AssetEntry` slice + open `Io.Dir` | Files appear at theme-relative paths; parent dirs created | Deterministic, sorted order; parent directory creation |
| `referencedAssetMaterial` | `pub fn` | Compute fingerprint material for referenced assets and footer | Bundle + path list + `include_footer` flag | Length-prefixed byte blob, or empty slice when nothing referenced | Fingerprint stability; deduplication and sorting of referenced paths |
| `scrubOrphanThemeAssets` | `pub fn` | Remove output assets not in current inventory, protect page outputs | `out_dir` + live inventory + page-output map | Orphan files deleted; live assets and page outputs preserved; empty tree removed when inventory empty | False-orphan protection; best-effort error swallowing |
| `"themeRootFromLayoutPath derives parent of layouts/"` | test | Directly exercises `themeRootFromLayoutPath` | Literal path strings | Correct slice or null for each case | All documented path patterns |
| `"validateAssetUrlPath rejects escapes and non-ASCII"` | test | Exercises `assemble.validateAssetUrlPath` from theme context | Various path strings | Acceptance for valid path; `error.InvalidAssetUrl` for `..`, spaces, non-ASCII | Cross-module path grammar enforcement |
| `"loadThemeBundle and copy with collision detection"` | test | Full integration: load, validate, copy, fingerprint, collision | Real tmp dir; 1 CSS asset + footer | Bundle fields correct; copy produces readable file; material non-empty; collision detected | End-to-end load-to-copy path |
| `"empty theme root yields empty bundle"` | test | Exercises legacy fallback path | Empty string theme root | Empty bundle, zero assets, zero footer bytes | Legacy layout without managed theme |
| `"loadThemeBundle rejects invalid UTF-8 in footer.html"` | test | UTF-8 gate on footer | Tmp dir; truncated UTF-8 byte in footer, then valid UTF-8 | `error.FooterInvalidUtf8` for bad bytes; success with valid UTF-8 including multibyte | Footer UTF-8 parity with layout gate (#62) |
| `"scrubOrphanThemeAssets removes deleted and renamed assets"` | test | Orphan deletion and empty-tree removal | Tmp out dir; prior build had 3 assets; live inventory has 1 | Orphans deleted; live asset kept; empty tree removed on zero-inventory call | Orphan scrub correctness |
| `"scrubOrphanThemeAssets preserves page outputs published under assets/"` | test | False-orphan protection | Tmp out dir; 1 theme asset + 1 page output under `assets/`; live inventory has 1 theme asset | Theme asset kept; page output NOT deleted; page output survives zero-inventory call | `page_outputs` map guards against false-positive scrub |
| `"loadThemeBundle rejects asset file symlink when host allows"` | test | Symlink rejection within asset tree | Tmp dir; real CSS file with symlink sibling; non-Windows only | `error.AssetSymlink` | Symlink traversal prevention |

## Hostile-case walkthrough

### `themeRootFromLayoutPath` — legacy and bare paths

**Injected behavior:**  
The function is called with `"layouts/main.html"` (legacy layout at the repo root), `"main.html"` (bare filename), and `"layouts/nested/main.html"` (nested, which is a path with a slash after `layouts/`).

**Wrapper boundary exercised:**  
`themeRootFromLayoutPath` — specifically the `std.mem.startsWith` guard for `"layouts/"` at the repo root level and the `indexOfScalar(u8, after, '/')` check for nested paths.

**Expected response:**  
`null` is returned for all three. The test asserts `themeRootFromLayoutPath("layouts/main.html") == null`, `themeRootFromLayoutPath("main.html") == null`, and `themeRootFromLayoutPath("layouts/nested/main.html") == null`.

**Forbidden unsafe response:**  
Returning a non-null slice that points into a freed or invalid region; returning a slice that would later be treated as a real theme root directory and cause spurious filesystem calls.

**Evidence strength:** directly demonstrated.

**Residual gap:**  
Paths with Windows-style backslash separators are not tested. Paths where `layouts/` appears as a suffix rather than a segment (e.g., `my-other-layouts/main.html`) are not tested.

***

### `validateThemeRootPath` — absolute and escape segments

**Injected behavior:**  
Called with strings beginning with `/`, `\\`, a drive prefix like `C:`, containing `..` or `.` segments, or containing empty segments (consecutive slashes).

**Wrapper boundary exercised:**  
`validateThemeRootPath` — the early-exit guards for `path[^1_0]`, `path[^1_1] == ':'`, and the segment loop that checks for `.` and `..` equality and for zero-length segments.

**Expected response:**  
`error.InvalidThemePath` for each hostile input. Valid relative multi-segment paths succeed.

**Forbidden unsafe response:**  
Accepting a path that, when used as an argument to `cwd.openDir` or `cwd.statFile`, could reference a directory outside the expected content tree.

**Evidence strength:** structurally checked (the validation function is called before every filesystem operation on the theme root; the test for `themeRootFromLayoutPath` does not directly test `validateThemeRootPath`, but `loadThemeBundle` calls it on every non-empty theme root). No dedicated test block for `validateThemeRootPath` itself appears in the file. The path grammar rules are enforced by code logic.

**Residual gap:**  
No dedicated test block for `validateThemeRootPath` with adversarial inputs is present. The function is exercised indirectly through `loadThemeBundle` integration tests, but the full hostile path matrix is not directly verified by a standalone test.

***

### `loadThemeBundle` — symlink at asset file level

**Injected behavior:**  
A real CSS file (`real.css`) is created in the theme's `assets/css/` directory. A symlink (`docs.css`) pointing to `real.css` is created in the same directory. `loadThemeBundle` is called with that theme root.

**Wrapper boundary exercised:**  
`loadThemeBundle` → `scrubOrphanThemeAssetsInner` … no, specifically the walker loop inside `loadThemeBundle` that checks `entry.kind == .sym_link` and the `rejectSymlinkAlongRel` call that stats each progressive path component with `follow_symlinks = false`.

**Expected response:**  
`error.AssetSymlink` is returned before any asset bytes are read.

**Forbidden unsafe response:**  
Following the symlink and reading its target; constructing an `AssetEntry` whose `bytes` field was loaded by traversing a symlink; silently ignoring the symlink and treating it as a regular file.

**Evidence strength:** directly demonstrated (test runs on non-Windows only; Windows is explicitly skipped).

**Residual gap:**  
Symlinks at intermediate directory levels within `assets/` (e.g., a symlink directory `assets/css -> /etc`) are tested via `rejectSymlinkAlongRel`, but only file-level symlinks are directly demonstrated by the test. Directory symlinks within the theme root are covered by the `rejectIfSymlink` call on the theme root itself, but a symlink directory nested inside `assets/` is not directly tested. Hard links to files outside the theme are not addressed.

***

### `loadThemeBundle` — invalid UTF-8 in `footer.html`

**Injected behavior:**  
A `footer.html` containing the byte sequence `ok\xc3` (a valid ASCII prefix followed by a truncated two-byte UTF-8 sequence) is written to the theme root. `loadThemeBundle` is called.

**Wrapper boundary exercised:**  
The `std.unicode.utf8ValidateSlice(bytes)` call inside `loadThemeBundle` after reading footer bytes, guarded by `if (bytes.len > 0 and ...)`.

**Expected response:**  
`error.FooterInvalidUtf8`. The `errdefer gpa.free(bytes)` ensures the loaded bytes are freed before the error propagates; the `errdefer bundle.deinit()` at the top of `loadThemeBundle` ensures the entire partially-constructed bundle is cleaned up.

**Forbidden unsafe response:**  
Storing invalid UTF-8 bytes in `ThemeBundle.footer_bytes` and returning a success; injecting the invalid bytes into every page via `&#123;&#123;footer&#125;&#125;`; leaking the allocated footer byte slice on error.

**Evidence strength:** directly demonstrated.

**Residual gap:**  
Empty `footer.html` (zero bytes) is not tested explicitly; the guard `if (bytes.len > 0 and ...)` means an empty footer silently passes the UTF-8 check. This is consistent with the intent (empty footer is valid), but is not directly tested. Non-UTF-8 bytes that happen to pass `utf8ValidateSlice` due to implementation bugs in the standard library are not within scope of this test.

***

### `scrubOrphanThemeAssets` — orphan deletion and empty-tree removal

**Injected behavior:**  
The output directory is seeded with three files from a simulated prior build: `assets/css/old.css`, `assets/css/keep.css`, and `assets/fonts/gone.woff`. The live inventory contains only `assets/css/keep.css`. A zero-inventory second call follows.

**Wrapper boundary exercised:**  
`scrubOrphanThemeAssetsInner` — specifically the `live` hash map membership test, the orphan collection loop, the `deleteFile` calls, and the `anyPageOutputUnderAssets` guard on whole-tree deletion.

**Expected response:**  
After the first call: `keep.css` is accessible; `old.css` and `gone.woff` produce `error.FileNotFound` on `access`. After the zero-inventory second call: the entire `assets/` directory produces `error.FileNotFound`.

**Forbidden unsafe response:**  
Deleting `keep.css` (a live asset); deleting a content page output that happens to reside under `assets/`; leaving orphan files after the scrub; panicking or returning an error through the `void` wrapper.

**Evidence strength:** directly demonstrated.

**Residual gap:**  
The empty-directory pruning (`deleteDir` on parent paths) is attempted but errors are silently swallowed. The test only verifies that the targeted orphan files are gone; it does not verify that empty intermediate directories are also removed. The interaction between `deleteDir` swallowing an error and a subsequent scrub pass is untested.

***

### `scrubOrphanThemeAssets` — false-orphan protection for page outputs under `assets/`

**Injected behavior:**  
Output directory contains `assets/css/theme.css` (a live theme asset) and `assets/css/docs.html` (a content page published under `assets/`). The live inventory contains only `theme.css`. The `page_outputs` map contains `"assets/css/docs.html"`. A zero-inventory second call is also made with the same `page_outputs` map.

**Wrapper boundary exercised:**  
The `page_outputs.contains(rel)` check inside `scrubOrphanThemeAssetsInner`; the `anyPageOutputUnderAssets(page_outputs)` guard before `deleteTree`.

**Expected response:**  
Both `theme.css` and `docs.html` survive the first call. `docs.html` also survives the zero-inventory second call (which would otherwise trigger `deleteTree`).

**Forbidden unsafe response:**  
Treating `docs.html` as an orphan theme asset and deleting it; calling `deleteTree` on `assets/` when any live page output is published there.

**Evidence strength:** directly demonstrated.

**Residual gap:**  
The `page_outputs` map is populated by the caller (the build pipeline), not by `theme.zig` itself. If the caller fails to include a page output in the map, `scrubOrphanThemeAssets` will silently delete it. This is not a defect in `theme.zig` but is a contract imposed on callers that is not enforced within the module.

***

### `referencedAssetMaterial` — empty reference set

**Injected behavior:**  
`referencedAssetMaterial` is called with an empty `referenced_paths` slice and `include_footer = false`.

**Wrapper boundary exercised:**  
The early-return guard `if (!include_footer and referenced_paths.len == 0) return try gpa.dupe(u8, "")`.

**Expected response:**  
An empty slice of length zero is returned. This preserves legacy digests: a layout that references no asset URLs and has no footer slot should produce the same fingerprint material as before F9 was introduced.

**Forbidden unsafe response:**  
Returning a non-empty slice; allocating and then leaking intermediate buffers.

**Evidence strength:** directly demonstrated.

**Residual gap:**  
The deduplication logic (removing duplicate entries from `referenced_paths`) is not tested with a duplicate-containing input in the inline tests. Only the empty and single-element cases are tested.

## Control flow

```text
loadThemeBundle(io, gpa, cwd, theme_root)
    └─ validateThemeRootPath(theme_root)         → error.InvalidThemePath on escape
    └─ rejectIfSymlink(io, cwd, theme_root)      → error.ThemeSymlink if sym_link
    └─ [footer.html]
        └─ cwd.statFile(footer_rel, follow_symlinks=false)
            → if sym_link: error.FooterSymlink
            → if file: readFileAlloc → utf8ValidateSlice
                → if invalid: error.FooterInvalidUtf8
    └─ [assets/ directory]
        └─ cwd.statFile(assets_root, follow_symlinks=false)
            → if sym_link: error.AssetSymlink
            → if not directory: error.InvalidThemePath
            → if directory:
                └─ walkSelectively (recursive)
                    └─ for each entry:
                        → if sym_link: error.AssetSymlink
                        → assemble.validateAssetUrlPath(rel) → error.InvalidAssetUrl
                        → rejectSymlinkAlongRel(io, cwd, full_under_theme)
                            → stat each progressive component
                            → if sym_link: error.AssetSymlink
                        → readFileAlloc → AssetEntry appended
        └─ std.mem.sort(AssetEntry, ...) [deterministic order]
        └─ list.toOwnedSlice → bundle.assets

scrubOrphanThemeAssets(io, out_dir, gpa, live_assets, page_outputs)
    └─ [errors swallowed by void wrapper]
    └─ scrubOrphanThemeAssetsInner
        └─ out_dir.openDir("assets", .{iterate=true})
            → error.FileNotFound → return (no assets dir, no-op)
        └─ build live StringHashMap from live_assets
        └─ walkSelectively → collect orphan paths (not in live, not in page_outputs)
        └─ for each orphan:
            └─ out_dir.deleteFile(rel) [error swallowed]
            └─ walk parent chain: out_dir.deleteDir(parent) [error swallowed]
        └─ if live_assets.len == 0 and !anyPageOutputUnderAssets(page_outputs):
            └─ out_dir.deleteTree("assets") [error swallowed]
```
