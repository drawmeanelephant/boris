---
title: "`src/content_asset.zig` overview"
id: docs/boris/src/content_asset
status: draft
tags: [boris, zig, source-reference, content_asset]
---

# `src/content_asset.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/content_asset/surface-and-execution|Surface and execution]]
* [[docs/boris/src/content_asset/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/content_asset/review-state|Review state]]

## Executive summary

`src/content_asset.zig` implements **content-local page asset publishing** for the Boris HTML path. A Markdown (or Textile-adapted) page may keep opaque sibling files under an exact tree named `{source-stem}.assets/`. Boris discovers regular files in that tree, rewrites safe relative Markdown image destinations into target-owned published URLs, copies asset bytes into the HTML output tree, collision-checks against page HTML and theme assets, and scrubs orphaned content-local outputs on later builds. Theme-owned `assets/` trees remain a separate subsystem (`theme.zig`). Asset **file bytes are never mixed into page HTML fingerprints**: an asset-only byte change republishes the file without re-rendering page HTML. Normative product contract: `docs/contracts/content-local-assets.md`.

The module is deliberately small and data-oriented. It owns path grammar for within-tree relative paths, inventory structs (`AssetEntry`, `PageAssetBundle`, `SiteAssetInventory`), Markdown image scanning outside fences, destination validation (no `..`, absolute, backslash, or out-of-tree resolve), GPA-owned file bytes, deterministic sort/copy order, and diagnostic printing mapped to `diag.Code.EASSET` / `EIO`. It does not open the content root itself for site-wide discovery (callers pass `content_dir` and parallel `source_paths` / `entity_ids`), does not run Apex, and does not write cache manifests.

Primary production caller is `compile.zig`’s `compilePagesInner`: load inventory after theme setup → `checkCollisions` vs page and theme outputs → `copyAssetsToOutput` into the **stage** directory → every fingerprint pass calls `rewriteImageLinks` on the page body (even when HTML will be cache-skipped) → after publish, `scrubOrphanContentAssets` on final dist. Integration tests live both in this file and as end-to-end cases in `compile.zig` (happy path, byte-change no re-render, traversal reject, symlink, stale cleanup, multi-target isolation, dual-build determinism).

Confidence is high for discovery sort, rewrite/passthrough rules, collision detection, scrub isolation from theme paths, and path hostility covered by unit + compile tests. Gaps: Windows symlink cases skip when the host denies symlink creation; image syntax is a closed Markdown subset (not full CommonMark link destinations); empty image destinations are left for Apex rather than hard-failed here; scrub delete errors are swallowed by design.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production library module with embedded unit tests |
| Conceptual domain | Content-local assets; Markdown image rewrite; publish/copy/scrub; path security |
| Build or test root | `content_asset` module in `build.zig`; tests via `zig build test` (`runcontentassettests`); also exercised through `compile` tests |
| Production runtime dependency | Yes — HTML compile path only (not IR/RAG emit) |
| Expected execution command | `zig build test`; product HTML: `boris` / `--html` / `--target` with pages that use `stem.assets/` |
| Main collaborators | `identity.zig` (`relativeHref`), `include.zig` (`FailInfo`, `lineColAt`, fence helpers patterns), `diag.zig` (codes/print shape), `compile.zig` (orchestration), `theme.zig` (collision peer; separate scrub) |
| Documentation depth warranted | High — security-sensitive path surface and fingerprint non-inclusion are easy to get wrong |

## Role in the Boris architecture

```text
content/{page}.md
content/{page}.assets/**          ← this module inventories & copies
        │
        ▼
loadSiteAssets / loadPageAssets
        │
        ├─► checkCollisions(content outs, page HTML outs, theme outs)
        ├─► copyAssetsToOutput → stage (then stage commit with HTML)
        ├─► rewriteImageLinks(body) → relative hrefs before Apex
        └─► scrubOrphanContentAssets(final dist) after publish
```

- **Product binary:** linked through `compile` → `main` HTML path; own test module without Apex.
- **vs `theme.zig`:** theme assets live under `{themeRoot}/assets/` and publish as `assets/...`; content-local publish as `{entity_id}.assets/{within}`. Scrub must never delete the other family’s files (`isContentLocalOutputPath` vs theme `assets/` prefix).
- **vs `cache.zig` / fingerprints:** compile validates images every build; **does not** feed asset bytes into `computePageFingerprint*`. Documented and tested: asset byte change → `pages_written == 0`, file on disk updates.
- **vs IR/RAG:** no content-local asset pipeline on those modes in this module.
- **Byte size (bundle):** ~39885 bytes packed source document.
