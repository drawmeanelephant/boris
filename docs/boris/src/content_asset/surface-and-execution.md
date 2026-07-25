---
title: "`src/content_asset.zig` surface and execution"
id: docs/boris/src/content_asset/surface-and-execution
parent: docs/boris/src/content_asset
status: draft
tags: [boris, zig, source-reference, surface, content_asset]
---

# `src/content_asset.zig` surface and execution

## Authoring model (normative shape)

```text
content/guides/intro.md
content/guides/intro.assets/diagram.svg
content/guides/intro.assets/nested/a.png
```

| Concept | Rule |
| :-- | :-- |
| Sibling root | `{sourceStem(source_path)}.assets` content-root-relative |
| Stem stripping | `.mdx` (4), `.md` (3), `.textile` (8); else whole path |
| Within-tree path | ASCII `A–Z a–z 0–9 . _ -` segments; `/` only; no empty, `.`, `..`; no leading `/` or `\` |
| Published path | `{entity_id}.assets/{within_tree}` (entity id, not source stem — **id override** changes URL namespace) |
| Inventory sort | `within_tree` ascending |
| Symlinks | Leaf and discovery reject `AssetSymlink`; must be regular files |
| Markdown images | Inline `![alt](dest)` / angle form outside fenced code; passthrough schemes unchanged |

## Key types

| Type | Role |
| :-- | :-- |
| `AssetError` | `AssetPath`, `AssetMissing`, `AssetSymlink`, `AssetNotFile`, `AssetCollision`, `ReadFailed`, `OutOfMemory` |
| `FailInfo` | Alias of `include.FailInfo` (locus, detail, line/col) |
| `AssetEntry` | `within_tree`, `source_rel`, `output_rel`, GPA-owned `bytes` |
| `PageAssetBundle` | Per-page inventory; owns root string + entries; `findWithin`; `deinit` |
| `SiteAssetInventory` | `pages: []PageAssetBundle` parallel to PageDb order; `collectOutputPaths`; `deinit` |
| `ImageHit` (private) | Scan result: dest slice, offsets, line/col, angle flag |

## Public API surface

| Function | Kind | Purpose |
| :-- | :-- | :-- |
| `sourceStem` | pub | Strip page extension from content-relative source path |
| `assetRootForSource` | pub | Allocate `{stem}.assets` |
| `outputRelFor` | pub | Allocate `{entity_id}.assets/{within}` |
| `validateWithinTreePath` | pub | Conservative within-tree grammar |
| `isPassthroughImageDest` | pub | `https:`, `http:`, `//`, `data:`, `mailto:` → no rewrite |
| `stripDotSlash` | pub | Single leading `./` strip |
| `loadPageAssets` | pub | Walk sibling tree for one page; sort; load bytes |
| `loadSiteAssets` | pub | Parallel arrays of source paths + entity ids |
| `rewriteImageLinks` | pub | Rewrite local images; return body (same slice if no hits) |
| `checkCollisions` | pub | Content vs page vs theme; uniqueness across content outputs |
| `copyAssetsToOutput` | pub | Deterministic write of all entries under `outdir` |
| `isContentLocalOutputPath` | pub | True if a published rel path is under a `*.assets` file tree |
| `scrubOrphanContentAssets` | pub | Delete published content-local files not in live inventory; never touch theme `assets/` |
| `printDiagnostic` | pub | Map errors to `EASSET`/`EIO` + remediation text |

## Path security model

| Attack / mistake | Handling |
| :-- | :-- |
| `../secret.png` in image dest | `AssetPath` after segment or resolve check |
| Absolute `/abs.svg` or `C:\…` | `AssetPath` |
| Backslash separators | `AssetPath` |
| Dest outside sibling `.assets` tree | `AssetPath` / resolve fail |
| Missing inventoried file | `AssetMissing` |
| Symlink leaf or walk entry | `AssetSymlink` |
| Non-file under tree | `AssetNotFile` |
| Same publish path as page HTML or theme asset | `AssetCollision` |
| Two pages producing same `output_rel` | `AssetCollision` (cross-page uniqueness) |
| Remote / data / mailto images | Passthrough; not fetched |
| Image-like text inside fences | Not scanned |

Within-tree filenames are **stricter** than arbitrary Unicode filenames: only the conservative ASCII set. That is intentional (portable URLs, no surprising percent-encoding surface in this layer).

## Integration with `compile.zig` (confirmed call sites)

1. After theme load/copy into stage: `loadSiteAssets(io, gpa, content_dir, source_paths, entity_ids)`.
2. `collectOutputPaths` + page outs + theme outs → `checkCollisions`.
3. `copyAssetsToOutput(io, stage_dir, inv)` — assets land in stage with HTML.
4. Fingerprint loop: `rewriteImageLinks` on body; free rewritten buffer if newly allocated; **asset bytes not hashed**.
5. `renderAndPublishPage` receives `page_assets` for body pipeline (html_body path can use bundle when rendering).
6. Full-rebuild stale HTML walk skips `isContentLocalOutputPath` and content-local `.html` embeds listed from inventory.
7. `scrubOrphanContentAssets(io, dist_dir, gpa, inv)` after theme scrub.

Multi-target: each target stages/copies into its own `dist`; inventories are rebuilt per target compile from the same content tree; tests prove mutating one target’s published asset does not change the sibling target’s copy.

## Ownership and allocation

| Resource | Owner | Notes |
| :-- | :-- | :-- |
| `source_path` / `entity_id` on bundle | Caller views | Not freed by bundle |
| `source_asset_root` | Bundle GPA | Freed in `deinit` if non-empty |
| Entry strings + bytes | Bundle GPA | Per-entry free in `deinit` |
| `rewriteImageLinks` output | Caller GPA/arena | Free if `ptr != body.ptr` |
| `collectOutputPaths` slice | Caller GPA | Views into entry `output_rel` |
| Site inventory pages array | Inventory GPA |  |

No global mutable state. Safe to call from sequential compile coordinator; parallel HTML workers receive **const** `PageAssetBundle` pointers and must not mutate inventory.

## Diagnostics

`printDiagnostic` maps:


| Error | Code | Message gist | Remediation gist |
| :-- | :-- | :-- | :-- |
| `AssetPath` | `EASSET` | invalid or out-of-tree image path | relative under `stem.assets`, no abs/`..`/`\` |
| `AssetMissing` | `EASSET` | asset not in sibling tree | place file under sibling `.assets` |
| `AssetSymlink` | `EASSET` | rejects symlinks | use regular files |
| `AssetNotFile` | `EASSET` | must be regular file | same |
| `AssetCollision` | `EASSET` | collides with page or theme | rename |
| other / IO | `EIO` | IO failure | readability |

Compile maps rewrite failures to `error.AssetFailed` after printing when not quiet.

## What this file does not do

- Fetch remote images or rewrite passthrough URLs.
- Inventory or copy theme `assets/` (see `theme.zig`).
- Include asset bytes in cache fingerprints (by design).
- Parse full CommonMark (reference-style images, HTML `<img>`, title-heavy edge cases beyond the local scanner).
- IR/RAG packaging of binary assets.
- Watch-mode path classification (watch may rebuild compile, which re-enters this module).
