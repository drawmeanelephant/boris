---
title: "`src/theme.zig` overview"
id: docs/boris/src/theme
status: draft
tags: [boris, zig, source-reference, theme]
---

# `src/theme.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/theme/surface-and-execution|Surface and execution]]
* [[docs/boris/src/theme/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/theme/review-state|Review state]]

## Executive summary

`src/theme.zig` implements the F9 theme subsystem for Boris. Its responsibilities are: deriving a canonical theme root directory from a layout path; validating that theme root path against a path-injection grammar; loading a `ThemeBundle` — the complete set of theme-owned materials for one build target, comprising an optional `footer.html` fragment and an inventoried, sorted set of opaque asset files residing under the theme's `assets/` subtree; enforcing that no asset path is a symlink at any progressive path component; UTF-8 gating `footer.html` with the same rule applied to layout files; computing fingerprint material for referenced assets and the footer; detecting collisions between asset output paths and content page output paths; copying inventoried assets into the output directory in deterministic order; and scrubbing orphan theme assets from a prior build's output tree while protecting content pages that legitimately publish under `assets/`.

The file exists because Boris separates content compilation from theme asset management. A theme owns trusted layout files and associated static resources; the compiler must copy those assets into every target output without fetching remote stylesheets, without following symlinks, and without leaving stale assets from renamed or removed files in the output directory. These invariants require a dedicated load-and-validate phase before any page is written.

The system boundary protected is the interface between the host filesystem and the compiler's output directory: symlink traversal, path escape via `..` segments or absolute prefixes, invalid UTF-8 in injected footer content, asset-to-page-output collisions, and wholesale deletion of page outputs during orphan scrubbing are all blocked at this layer.

Execution occurs as part of the normal `zig build test` run. The file's `test` blocks are inline and exercise the same functions used in production. There is no separate test-only module or hostile double. Confidence provided: all named error conditions — missing theme root, symlinks at the theme root and within the asset tree, invalid UTF-8 in footer, invalid path grammar, asset collision with page output, orphan scrub of deleted and renamed assets, and protection of page outputs published under `assets/` — are directly demonstrated by integration tests that use real temporary directories on the host filesystem. What the tests do not prove: behavior on filesystems that do not enforce `follow_symlinks = false` correctly; Windows-specific path grammar edge cases (the symlink test is explicitly skipped on Windows); behavior when `walkSelectively` emits entries in a non-deterministic order across platforms; atomicity of the copy-to-output step under concurrent access; and the correctness of the `createDirPath`/`writeFile` sequence when the target directory is on a remote filesystem.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with inline integration tests |
| Conceptual domain | Theme asset management, path security, output lifecycle |
| Build or test root | Compiled into the product binary; tests run via `zig build test` |
| Production runtime dependency | Yes — `loadThemeBundle`, `copyAssetsToOutput`, `scrubOrphanThemeAssets`, and `referencedAssetMaterial` are called by the build pipeline |
| Expected execution command | `zig build test` (tests); included in the default product binary |
| Main collaborators | `src/assemble.zig` (imports `LayoutError`, `validateAssetUrlPath`); `std.Io`, `std.mem.Allocator`, `std.fs.path`, `std.unicode`, `std.StringHashMapUnmanaged` |
| Documentation depth warranted | Medium-high — path-security invariants and orphan-scrub edge cases merit detailed documentation |

## Role in the Boris architecture

`src/theme.zig` is a production module linked into the product binary. It is not test-only. Its public API is the bridge between theme source directories on disk and the compiler's output phase: `loadThemeBundle` must complete before any page can be assembled, because `ThemeBundle` holds the footer bytes injected via `&#123;&#123;footer&#125;&#125;` slots and the asset bytes copied to `out/`. `requireReferencedAssets` and `checkAssetPageCollisions` are preflight validators that run before any file is written to the output directory. `copyAssetsToOutput` and `scrubOrphanThemeAssets` are the write-side counterparts, called after pages are published.

Relative to `src/assemble.zig`: `theme.zig` imports `assemble.LayoutError` to extend `ThemeError`, and calls `assemble.validateAssetUrlPath` to enforce the same ASCII path grammar on inventoried asset paths as the layout splicing layer enforces on `&#123;&#123;asset-url …&#125;&#125;` references. This ensures that an asset that passes inventory validation will also pass layout reference validation. The inline test `"validateAssetUrlPath rejects escapes and non-ASCII"` in `theme.zig` exercises `assemble.validateAssetUrlPath` directly, providing cross-module test coverage at the theme integration boundary.

There is no ApexMarkdown dependency, no `src/apex.zig` import, and no C ABI involvement in this file. It is entirely Zig standard library and `assemble.zig`.
