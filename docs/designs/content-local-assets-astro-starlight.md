# Content-local assets ↔ Astro / Starlight migration

**Status:** design / compatibility note (not a product runtime dependency)  
**Normative behavior:** [`docs/contracts/content-local-assets.md`](../contracts/content-local-assets.md)

This note explains how Boris’s post-v0.5.0 **sibling `{page}.assets/`** slice
relates to image/asset patterns authors meet when leaving Astro or Starlight.

## What Boris ships in this slice

- Per-page ownership only: files live under the exact sibling of the Markdown
  source (`guides/intro.md` → `guides/intro.assets/…`).
- Markdown **image** destinations only (not raw HTML `<img>`).
- Opaque byte copy + page-relative URL rewrite.
- Fail-closed path grammar (no `..`, absolute paths, backslashes, symlinks).
- Theme chrome stays under the theme’s `assets/` via `{{asset-url …}}`.
- Asset **byte** changes do not force HTML re-render when the page body is
  unchanged.

It does **not** implement Astro’s import graph, Starlight’s public-dir merge,
image optimization pipelines, or a site-wide `src/assets` bucket.

## Common Astro / Starlight shapes

| Framework pattern | Typical meaning | Boris mapping |
|-------------------|-----------------|---------------|
| `./diagram.svg` next to the page | File co-located with Markdown | Move into `{stem}.assets/diagram.svg` and reference `intro.assets/diagram.svg` (from `intro.md`) |
| `src/assets/…` or `src/content/…` shared media | Site-wide media graph resolved by the bundler | **Out of scope** for this slice — either promote into each page’s sibling tree, or keep as theme/static bytes under a managed theme `assets/` |
| `public/images/…` | Copied as-is to site root | Not content-local; treat as future static publish or theme assets |
| `import img from './x.png'` + `<Image />` | Bundler-processed component | Replace with Markdown `![…](…assets/…)` or raw HTML (raw HTML is not rewritten) |
| Remote CMS / CDN URLs | Runtime or build-time fetch | Passthrough `https://…` only; Boris never fetches |

## Recommended migration steps

1. **Inventory** page-adjacent media (Starlight/Astro migration labs already
   record content-local candidates for authors).
2. **Relocate** each page’s owned files into `{page-stem}.assets/`, preserving
   nested subfolders when useful (`nested/shot.png`).
3. **Rewrite** Markdown image destinations to relative paths under that tree.
4. **Split chrome vs content:** site CSS/fonts/icons → theme `assets/` +
   `{{asset-url}}`; page diagrams/screenshots → sibling `.assets/`.
5. **Drop bundler-only features** (responsive `srcset` generation, automatic
   format conversion). Ship final bytes authors want in `dist/`.
6. **Validate** with a multi-target HTML build: content-local paths must not
   collide with theme `assets/` or page HTML outputs.

## Compatibility boundaries (intentional)

- **Stricter than co-located `./file.png`:** Boris requires the `.assets`
  suffix so page discovery never confuses media with page sources and so stale
  cleanup can target `*.assets/` without touching theme `assets/`.
- **No shared content media root:** avoids cross-page coupling and undeclared
  reverse dependencies in the first slice. Shared libraries can wait for an
  explicit graph edge design.
- **No IR schema change:** assets are an HTML publish concern; machine IR stays
  page/graph-centric.
- **Labs stay labs:** `tools/migration-lab` may report content-local files; it
  is not a runtime dependency of `boris` HTML compile.

## Acceptance mental model

Authors should be able to open published HTML from `dist/` offline and see
page diagrams load via relative URLs next to the page (`*.assets/`), while site
chrome still comes from target-owned theme `assets/`. That separation is the
compatibility win versus framework-global asset graphs.
