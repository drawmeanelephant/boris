# WordPress Theme Test Data Demo

This is the reproducible demo companion for Boris's WordPress migration lab.
It starts with WordPress Theme Unit Test-style content, converts it into Boris
Markdown, validates the resulting Trunk/Satellite graph, and publishes a
static site with the Boris reference theme.

## What the demo proves

- 186 converted Markdown pages compile with zero diagnostics.
- 188 HTML pages are emitted, including the curated walkthrough pages.
- The same content tree produces JSON IR and a RAG corpus.
- The generated site includes navigation, breadcrumbs, table of contents,
  local theme assets, `Aside`, and `Details` examples.
- Preserved and uncertain migration material remains visible for review rather
  than being silently discarded.

The curated entry point is `dist/demo-index.html`. From there, the most useful
pages are:

- `dist/demo/walkthrough.html` — the migration story
- `dist/demo/components.html` — Boris `Aside` and `Details`
- `dist/demo/graph.html` — Trunk/Satellite relationships
- `dist/demo/ir-rag.html` — JSON IR and RAG outputs
- `dist/demo/review.html` — manual-review boundaries
- `dist/demo/reproduce.html` — the command sequence

## Local artifact

The complete generated packet is kept outside the tracked source tree because
it contains generated HTML, IR, RAG, and migration outputs:

```text
support/demo-site.zip
```

The packet is intentionally portable: it contains `content/`, `theme/`,
`dist/`, `ir/`, and `rag/`. It is approximately 1.2 MB compressed and 4.9 MB
expanded. Do not treat generated output as compiler source or commit it into
the core repository.

## Reproduce the proof

Build Boris and the migration lab from the repository root, then run the
WordPress lab against a local WXR export and local media directory. Compile
the resulting Markdown with a theme, and emit IR and RAG as separate outputs.
The exact commands and expected artifacts are recorded in the packet's
`dist/demo/reproduce.html` page.

The original WordPress export and media blobs are deliberately not bundled in
this repository. A reproduction therefore requires a local WXR fixture and
any media files used by that fixture.

## Scope and limitations

This is a migration-lab demonstration, not a WordPress runtime or universal
theme importer. PHP, JavaScript, remote assets, and ambiguous theme behavior
remain review items. The demo shows the safe path: preserve what can be
proven, report what needs a human decision, and compile the accepted content
with Boris.
