---
title: "`src/content_asset.zig` evidence and cases"
id: docs/boris/src/content_asset/evidence-and-cases
parent: docs/boris/src/content_asset
status: draft
tags: [boris, zig, source-reference, evidence, content_asset]
---

# `src/content_asset.zig` evidence and cases

## Control flow

### Discovery (`loadPageAssets`)

```text
asset_root = assetRootForSource(source_path)   // may not exist → empty bundle
openDir(asset_root) or empty
walkSelectively:
  directories: enter
  symlink entries: AssetSymlink
  non-files: skip / AssetNotFile as appropriate
  within = entry.path (normalized separators)
  validateWithinTreePath(within) else skip or fail per path rules
  source_rel = asset_root + "/" + within
  stat leaf follow_symlinks=false → symlink/not-file errors
  read bytes into GPA
  output_rel = outputRelFor(entity_id, within)
sort entries by within_tree
```

Missing asset root is success with zero entries (page may have no local images).

### Rewrite (`rewriteImageLinks`)

```text
scanImages(body) outside fences
if no hits → return body (same slice)
for each hit:
  if isPassthroughImageDest → copy dest unchanged
  else:
    reject backslash, absolute, drive, empty cleaned, . / .. segments
    if no source_asset_root → AssetMissing
    resolveAgainstSourceDir(page source, dest) → must land under asset root
    within = withinTreeOf(resolved, root)
    validateWithinTreePath + findWithin inventory
    href = identity.relativeHref(page_output_html, entry.output_rel)
    emit href (preserve author angle brackets when used)
return owned rewritten body
```

Compile always runs rewrite on the **body** (post-frontmatter) even when HTML is fingerprint-cached, so path errors still fail loud on no-op incremental builds when the Markdown link is bad.

### Collisions, copy, scrub

```text
checkCollisions:
  ∀ content output ∩ page HTML paths → AssetCollision
  ∀ content output ∩ theme paths → AssetCollision
  pairwise uniqueness among content outputs

copyAssetsToOutput:
  for each page, each entry (sorted inventory):
    create parent dirs; writeFile(output_rel, bytes)

scrubOrphanContentAssets:
  live set = all inventory output_rel
  walk outdir; keep only isContentLocalOutputPath files
  delete those not in live; swallow delete errors
  (theme assets/… never classified as content-local)
```

## Test suite

### Module tests (`src/content_asset.zig`)

| Test | Purpose | Expected | Contract |
| :-- | :-- | :-- | :-- |
| `isPassthroughImageDest` | Scheme allowlist | https/http/`//`/data/mailto true; local false | Passthrough |
| `isContentLocalOutputPath` | Classifier | `guides/intro.assets/x` true; `assets/css/…` and bare `.assets` dir false | Scrub/HTML stale skip |
| `loadPageAssets discovers nested files sorted` | Inventory order | `nested/a.png` then `z.svg`; correct source/output rel | Deterministic discovery |
| `rewriteImageLinks rewrites sibling and leaves remote` | Happy rewrite | local → relative published href; https unchanged | Core rewrite |
| `id override rewrites to entity-scoped asset URL` | Entity ≠ stem | `custom.assets/d.svg` in href when entity `custom` | id frontmatter |
| `rewrite skips fenced image-looking text` | Fence awareness | body unchanged | No false rewrite |
| `rewrite rejects traversal absolute backslash outside tree` | Hostility | `AssetPath` / `AssetMissing` | Path security |
| `copyAssetsToOutput and scrub orphans` | Publish + scrub | keep updated; drop removed + stale; theme CSS untouched | Copy/scrub isolation |
| `checkCollisions detects page and theme clashes` | Preflight | collisions error; disjoint paths ok | Collision matrix |

### Integration tests (`src/compile.zig`, content-local section)

| Test | Purpose | Expected |
| :-- | :-- | :-- |
| happy path rewrite and copy | E2E HTML + file | href contains `intro.assets/diagram.svg`; bytes match |
| byte change does not re-render HTML | Fingerprint policy | `pages_written == 0`; HTML identical; asset bytes v2 |
| rejects traversal outside tree | E2E fail | `AssetFailed` |
| rejects absolute and backslash destinations | E2E fail | `AssetFailed` |
| rejects symlink leaf when host allows | E2E fail | `AssetSymlink` (skip if AccessDenied) |
| stale cleanup and theme isolation | Scrub after delete | drop.svg gone; theme CSS remains; keep.svg remains |
| multi-target isolation and deterministic bytes | Two dists | equal payloads; mutate A leaves B |
| two builds are byte-identical | Determinism | HTML and assets match across fresh dists |
| example reference-theme | Dogfood | page-local SVG + theme CSS together |

## Hostile-case walkthroughs

### Path traversal image destination

**Injected:** `![x](../secret.png)` or `![x](../../etc/passwd)` with secret outside `.assets`.
**Boundary:** `rewriteImageLinks` segment/resolve/`withinTreeOf`.
**Expected:** `AssetPath`; compile → `AssetFailed`; no publish of secret.
**Forbidden:** Reading or copying files outside sibling tree.
**Evidence:** unit + compile hostile tests.
**Gap:** Does not claim TOCTOU against concurrent FS mutation during walk.

### Absolute / backslash destinations

**Injected:** `/abs.svg`, Windows-style backslash paths.
**Expected:** `AssetPath` / `AssetFailed`.
**Evidence:** directly demonstrated.

### Symlink asset leaf

**Injected:** `link.svg` → `real.svg` under `.assets`.
**Expected:** `AssetSymlink` at load.
**Evidence:** unit/compile when host allows symlinks; Windows may skip.
**Gap:** Intermediate directory symlink along progressive path is less emphasized than theme’s `rejectSymlinkAlongRel`; leaf + walk entry kinds are the primary gates.

### Asset-only byte change under incremental HTML

**Injected:** Change SVG bytes; leave Markdown and layout unchanged.
**Boundary:** fingerprint excludes asset bytes; copy always from inventory.
**Expected:** zero HTML pages written; published asset new bytes.
**Forbidden:** Forcing full site Apex re-render solely due to asset bytes.
**Evidence:** compile test `content-local assets byte change does not re-render HTML`.

### Collision with page or theme output

**Injected:** content output path equals `index.html` or `assets/css/docs.css`.
**Expected:** `AssetCollision` before publish.
**Evidence:** `checkCollisions` unit tests; theme collision also covered in theme/compile fixtures for the theme side.

### Orphan scrub must not touch theme

**Injected:** Prior `index.assets/stale.svg` + live theme `assets/css/docs.css`; remove drop from source.
**Expected:** stale/drop removed; theme CSS intact; keep retained.
**Evidence:** module scrub test + compile stale/theme isolation test.

### Id override namespace

**Injected:** page source `guides/intro.md` with entity id `custom`.
**Expected:** publish under `custom.assets/…`; hrefs use that prefix.
**Evidence:** unit test `id override rewrites to entity-scoped asset URL`.
**Note:** Two different source stems forced to the same entity id would collide on `output_rel` — caught by cross-page uniqueness if both have assets.
