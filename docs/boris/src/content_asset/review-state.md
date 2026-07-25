---
title: "`src/content_asset.zig` review state"
id: docs/boris/src/content_asset/review-state
parent: docs/boris/src/content_asset
status: draft
tags: [boris, zig, source-reference, review-state, content_asset]
---

# `src/content_asset.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and uncertain claims

- **Empty image dest `![]()`:** scanner continues without error; Apex may see empty dest later — not a hard `AssetPath` here.
- **Reference-style / HTML images:** not rewritten by this scanner; authors must use inline Markdown images for local assets.
- **Unicode filenames in `.assets`:** rejected by `validateWithinTreePath`; authors need ASCII names.
- **Symlink on Windows:** tests often early-return on `AccessDenied` — not a green proof on all CI hosts.
- **Scrub error swallowing:** delete failures do not fail the build; orphans might remain after FS errors.
- **Large binary memory:** entire asset files loaded into GPA for the compile duration — fine for docs sites; not a streaming copier.
- **Bundle source:** dossier from Space packed `src/content_asset.zig` (~39885 bytes) plus `compile.zig` call sites and `build.zig` module wiring.

## Potential follow-up work

- Optional streaming copy for very large binaries without holding all bytes in RAM for the whole site compile.
- Explicit contract test that HTML `<img src="...">` is intentionally not rewritten (document or implement).
- Align directory-symlink policy wording with `theme.zig` progressive reject if product wants parity.
- Cross-link this dossier from `docs/contracts/content-local-assets.md` operator section.
