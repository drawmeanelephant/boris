# Content-local page assets (post-v0.5.0)

**Status:** normative for the HTML path · test-driven  
**Modules:** `src/content_asset.zig`, `src/html_body.zig`, `src/compile.zig`  
**Does not change:** IR `schemaVersion`, frontmatter grammar, theme ownership,
or Apex trust model.

A Markdown page may reference **opaque local files** stored in an exact sibling
directory named after the page stem:

```text
content/guides/intro.md
content/guides/intro.assets/diagram.svg
content/guides/intro.assets/nested/shot.png
```

Boris discovers those files, copies them into each target output, rewrites safe
relative Markdown image destinations to published page-relative URLs, and
rejects traversal and cross-tree references. This is **not** a global media
library and **not** theme `assets/`.

---

## 1. Ownership and discovery

| Term | Meaning |
|------|---------|
| **Page source** | Content-root-relative path of a discovered page (e.g. `guides/intro.md`) |
| **Source stem** | Page source with the selected page extension stripped (`guides/intro`) |
| **Sibling asset root** | Exactly `{stem}.assets` next to the page (`guides/intro.assets`) |
| **Within-tree path** | Path under that root (`diagram.svg`, `nested/shot.png`) |
| **Published path** | Target-root-relative `{entity_id}.assets/{within-tree}` |

Rules:

1. Only the **exact** sibling tree is owned by the page. Sibling folders with
   other names, shared `static/` trees, and theme `assets/` are not content-local
   assets.
2. Discovery walks regular files under the sibling root recursively.
3. **Symlinks are rejected** (asset root, intermediate segments, and leaf files).
4. Directories are not publishable assets; only regular files are inventoried.
5. Missing sibling root is allowed (empty inventory).
6. Inventory order is bytewise sorted by within-tree path (deterministic copy).
7. Extension policy for pages is unchanged: non-page files under content are
   ignored by page discovery and only enter the build via this asset path.

Path grammar for within-tree segments (ASCII-only, fail closed):

- `/` separators only (no `\`)
- no absolute form, drive prefix, empty, `.`, or `..` segments
- each segment is `[A-Za-z0-9._-]+` only

---

## 2. Markdown image references

Only **inline Markdown image** syntax is rewritten:

```markdown
![alt](intro.assets/diagram.svg)
![alt](intro.assets/diagram.svg "title")
![alt](<intro.assets/diagram.svg>)
```

### Accepted destinations

| Destination | Behavior |
|-------------|----------|
| Relative path resolving into **this page’s** sibling asset root and present in the inventory | Rewrite to a page-relative published URL |
| `http://`, `https://`, `//`, `data:`, `mailto:` | **Passthrough** (not fetched, not copied) |

### Rejected destinations (`EASSET`)

- absolute paths (`/…`, Windows drive forms)
- backslashes
- any `..` or empty/`.` segment
- relative paths that resolve **outside** the owning page’s sibling tree
- missing inventory files
- destinations that would require publishing a directory as a file

**Out of scope (not rewritten, not validated as content-local assets):**

- raw HTML `<img src="…">`
- reference-style image definitions
- CSS `url(...)`
- remote fetching, resizing, hashing, or optimization
- global/shared content asset roots

Fence-aware: image-looking text inside fenced code blocks is left literal.

---

## 3. Published URLs and copy

For entity id `guides/intro` (default stem) and within-tree `diagram.svg`:

```text
dist/guides/intro.html
dist/guides/intro.assets/diagram.svg
```

From the page HTML, the rewritten destination is a **page-relative** path
(never a leading-`/` site-absolute path), e.g. `intro.assets/diagram.svg`.

When frontmatter `id:` overrides the entity id, discovery still uses the
**source** sibling tree, but published paths use the **entity id**:

```text
source:  guides/intro.md  +  guides/intro.assets/d.svg
id:      custom
output:  custom.html  +  custom.assets/d.svg
href:    custom.assets/d.svg
```

Copy rules:

- Target-owned: each target stages and publishes its own bytes.
- Deterministic: sorted inventory order; exact bytes; no host paths or mtimes in
  content.
- Theme `assets/` remains separate under the target root `assets/` prefix.
- Preflight **collision** when a content-local published path equals a page
  HTML output path or a theme asset path (`EASSET` / `AssetCollision`).

---

## 4. Incremental fingerprints and stale cleanup

**Page HTML fingerprints do not include content-local asset file bytes.**

- Changing only asset bytes republishes the file and does **not** force a page
  HTML re-render when the page body, includes, layout, theme material, and
  graph chrome inputs are unchanged.
- Image path text in the page body remains part of the ordinary source
  fingerprint (editing the Markdown destination dirties the page).
- Every build still **validates** local image destinations against the current
  inventory (including for cached pages) so a deleted asset fails loud instead
  of leaving a broken URL.

Stale cleanup:

- After successful publish, files under published `*.assets/` trees that are not
  in the live inventory are removed (delete/rename of source assets).
- Theme-owned `assets/` is never scrubbed by the content-local cleaner.
- Multi-target isolation is preserved: each target has its own output tree and
  scrub scope.

---

## 5. Diagnostics

| Code | When |
|------|------|
| `EASSET` | Invalid/out-of-tree path, missing file, symlink, non-file, or published-path collision |

Exit **1** (content) on `EASSET` during HTML compile. IR/RAG paths do not
publish content-local assets and do not rewrite Markdown images.

---

## 6. Explicit non-goals

- Remote fetch / CDN mirror
- Shared content-wide media directories
- Image processing, compression, width/height injection, content hashing of
  filenames
- IR schema fields for assets
- Raw HTML rewriting
- Node/Python/other runtime dependencies

---

## 7. Migration note (Astro / Starlight)

Astro and Starlight often keep images next to Markdown (`./image.png` or
`src/assets/…`) and resolve them through the framework bundler. Boris’s first
slice is stricter and more explicit:

1. Place page-owned files under `{page-stem}.assets/`.
2. Reference them with relative Markdown images into that tree only.
3. Theme chrome (site CSS/fonts) stays under the theme’s `assets/` via
   `{{asset-url …}}`.

Migration labs may inventory “content-local” files for authors; the product
compiler only publishes the sibling-tree contract above. See
[`docs/designs/content-local-assets-astro-starlight.md`](../designs/content-local-assets-astro-starlight.md).

---

## 8. Implementation map

| Concern | Module |
|---------|--------|
| Discover / validate / rewrite / copy / scrub | `src/content_asset.zig` |
| Pre-Apex image rewrite in body pipeline | `src/html_body.zig` |
| Site loop: inventory, collisions, stage copy, scrub | `src/compile.zig` |
| Theme assets (separate) | `src/theme.zig` |
