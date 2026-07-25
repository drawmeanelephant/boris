---
title: "`src/theme.zig` surface and execution"
id: docs/boris/src/theme/surface-and-execution
parent: docs/boris/src/theme
status: draft
tags: [boris, zig, source-reference, surface, theme]
---

# `src/theme.zig` surface and execution

## Threat model

The following categories of adversarial or malformed input are addressed by `theme.zig`:

**Path escape and injection**  
Theme root paths with an absolute prefix (`/` or drive letter `C:`), empty segments, `.`, or `..` are rejected by `validateThemeRootPath` before any filesystem call is made. Asset paths discovered during the walk are passed through `assemble.validateAssetUrlPath`, which enforces `assets/` prefix, ASCII-only characters, and the same anti-escape rules. A path like `assets/../etc/passwd` would be rejected by the `..` segment check. A path with non-ASCII bytes (including valid UTF-8 multibyte sequences) is rejected because `validateAssetUrlPath` permits only `A-Za-z0-9._-/`.

**Symlink traversal**  
The theme root itself, `footer.html`, and every progressive path component along each inventoried asset's path under the theme root are stat'd with `follow_symlinks = false`. Any `sym_link` kind at any of these points returns an error (`ThemeSymlink`, `FooterSymlink`, `AssetSymlink`) and aborts loading. The `loadThemeBundle rejects asset file symlink when host allows` test demonstrates this for an asset symlink. The symlink test is skipped on Windows (`if (@import("builtin").os.tag == .windows) return`), which is documented behavior.

**Invalid UTF-8 in footer**  
`footer.html` bytes are passed through `std.unicode.utf8ValidateSlice` after loading. A lone continuation byte or any truncated multibyte sequence returns `FooterInvalidUtf8`. This mirrors the UTF-8 gate applied to layout files in `assemble.zig` (`LayoutError.InvalidUtf8`). The test `"loadThemeBundle rejects invalid UTF-8 in footer.html"` directly demonstrates both the rejection and the acceptance of valid multibyte UTF-8 (café).

**Asset-to-page-output collision**  
`checkAssetPageCollisions` prevents a theme asset from overwriting a content page output by comparing `rel_path` strings. The test `"loadThemeBundle and copy with collision detection"` demonstrates both the acceptance path and the `AssetCollision` error.

**False orphan deletion of page outputs**  
`scrubOrphanThemeAssets` walks the output `assets/` directory and classifies each file as either live (in the current asset inventory), a live page output (in the `page_outputs` hash map), or an orphan. Only orphans are deleted. Two tests exercise this: `"scrubOrphanThemeAssets removes deleted and renamed assets"` confirms orphan deletion and whole-tree removal when inventory is empty; `"scrubOrphanThemeAssets preserves page outputs published under assets/"` confirms that a content page publishing to `assets/css/docs.html` is never deleted, even when the theme inventory is entirely empty.

**Best-effort error swallowing in scrub**  
`scrubOrphanThemeAssets` is a `void`-returning wrapper that calls `scrubOrphanThemeAssetsInner` and discards all errors. This is intentional: a cleanup failure must not roll back a successful HTML publish. This means that if `deleteFile` or `deleteDir` fails for any reason, no error is surfaced to the caller and no test verifies failure modes of the deletion itself.

**Mid-walk deletion race**  
`scrubOrphanThemeAssetsInner` collects all orphan paths into an `ArrayList` before deleting any of them, explicitly to avoid invalidating the walker while iterating. The comment in the source names this invariant.

**The following categories are not addressed or not tested:**  
- Concurrent access to theme directories or output directories  
- Hard link traversal (only symlinks are detected; hard links to files outside the theme are not rejected)  
- Case-sensitivity collisions on case-insensitive filesystems  
- Output file truncation or partial write during `copyAssetsToOutput` (no atomic write for assets; `writeFile` is used directly)  
- Recovery from a partial scrub (scrub errors are swallowed but not logged)
