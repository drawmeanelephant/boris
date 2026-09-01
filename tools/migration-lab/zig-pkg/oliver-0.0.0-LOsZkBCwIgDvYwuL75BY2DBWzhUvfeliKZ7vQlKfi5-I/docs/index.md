---
published_at: 2026-08-14T00:00:00Z
summary: Oliver documentation home: a small, freestanding markup parsing and rendering library in Zig.
---

# Oliver documentation

Oliver is a small, freestanding markup parsing and rendering library in
Zig: bytes in, a typed document (or Recipe) out, deterministic HTML on
request. This is the documentation home.

The documentation is written for two audiences:

- **Consumers** — applications (like Boris) that embed Oliver. Start
  with [Capabilities](CAPABILITIES.html) and the README's library-use and
  CLI sections, then the frontend pages that matter to you.
- **Contributors** — anyone changing Oliver. Start with
  [Architecture](ARCHITECTURE.html) and [Clean-room rules](CLEANROOM.html),
  then the per-feature parsing documents and the
  [work ledger](WORK-LEDGER.html).

## Conformance status

| wall | status |
| --- | --- |
| CommonMark 0.31.2 corpus | **652/652**, 0 mismatches |
| Cooklang canonical corpus | **60/60** |
| Textile fixture wall | fully green |
| Test suite | **280/280** |

Both conformance gates run in CI on every push/PR
(`zig build spec-conformance -- spec.txt --gate` and
`zig build cooklang-conformance`).

## Site map

`nav.json` is the machine-readable manifest — sections,
pages, titles, audiences, and summaries — that any docs renderer can
consume directly. The map below mirrors it.

### Overview

- [Capabilities](CAPABILITIES.html) — what each frontend parses and
  renders today, with conformance status (start here as a user)
- [Architecture](ARCHITECTURE.html) — pipeline, the two document
  families, module map, the boundaries that matter
- [Document model](DOCUMENT-MODEL.html) — the shared normalized model and
  its invariants
- [Feature matrix](FEATURE-MATRIX.html) — every implemented feature
  across the dialects, with provenance
- [Tests and fixtures](TESTS.html) — the suites, the conformance walls,
  and the fixture convention
- [XHTML output profile](XHTML.html) — the same IR and semantics under
  an XML-compatible serialization, the fail-closed raw-HTML policy, and
  the well-formedness gate
- [CommonMark expectations](COMMONMARK-EXPECTATIONS.html) — the
  classified conformance expectation set behind the 652/652 gate

### Markdown frontend

- [Block parsing](BLOCKS-PARSING.html) · [Leaf blocks](LEAF-BLOCKS.html) ·
  [Fenced code](FENCED-CODE.html) · [HTML blocks](HTML-BLOCKS.html) ·
  [Entities](ENTITIES.html)
- [Emphasis and strong](INLINE-PARSING.html) · [Autolinks](AUTOLINKS.html) ·
  [Raw HTML](RAW-HTML.html) · [Images](IMAGES-PARSING.html) ·
  [Reference images](REFERENCE-IMAGES.html) · [Tables (GFM)](TABLES.html) ·
  [Wikilinks](WIKILINKS.html) · [Callouts](CALLOUTS.html) ·
  [Smart typography](SMARTY.html) · [Front matter](FRONTMATTER.html)

### Textile frontend

- [Textile parity audit](TEXTILE-PARITY.html) · [Inline code
  contract](TEXTILE-INLINE-CODE.html)

### Cooklang frontend

- [Cooklang design contract](COOKLANG.html) — the typed Recipe model,
  the boundaries, and the serialize / scale / HTML / menu policies

### Process

- [Clean-room rules](CLEANROOM.html) · [Work ledger](WORK-LEDGER.html)

### Publications

- [GitHub Pages publication](github-pages.html) — how this docs tree
  publishes to GitHub Pages: enable the target, the pinned Boris
  toolchain, the `/oliver` project-site shape, the public/evidence
  boundary, and the optional post-deploy audit
- [Publication contracts](contracts/index.html) — the landing page for
  the normative contract set behind the publication pipeline
- Contracts: [model](contracts/publication-model.html) ·
  [profile](contracts/publication-profile.html) ·
  [plan](contracts/publication-plan.html) ·
  [checks](contracts/publication-checks.html) ·
  [claims](contracts/publication-claims.html) ·
  [artifacts](contracts/publication-artifacts.html) ·
  [touches](contracts/publication-touches.html) ·
  [proof pack](contracts/publication-proof-pack.html) ·
  [deployment evidence](contracts/github-pages-deployment-evidence.html)

## Rendering as pages

This tree currently renders and publishes through the GitHub Pages
workflow — see the [GitHub Pages publication](github-pages.html) guide.
`docs/nav.json` remains the single source of navigation truth and is kept
renderer-agnostic: the renderer, or any other docs generator (mdBook,
mkdocs, Docusaurus, or a hand-rolled one), can consume it directly or
transpile it to its own sidebar format. The markdown files are self-contained and
cross-linked, so any static renderer with a markdown engine can serve
them as-is — no repository restructuring is needed to ship pages.
