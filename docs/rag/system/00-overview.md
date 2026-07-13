---
rag_id: system/overview
rag_path: system/00-overview.md
category: system
tags: [boris, overview, content-compiler, zig]
related:
  - system/01-architecture-pipeline.md
  - system/02-data-model-page.md
  - system/03-trunk-and-satellite.md
  - system/04-components-and-admonitions.md
  - system/10-name-and-metaphor.md
---

# Boris overview

Boris is a **Zig content compiler for Markdown documentation** that is growing
into a full Apex-native static site generator. In **v0.1** the default product
surface is: discover content → bounded frontmatter → Trunk/Satellite graph
validation → deterministic JSON under `.boris/`. Optional: export an LLM RAG
corpus. HTML layout assembly exists as modules and unit tests but is **not**
the default CLI path.

The project is named for the folk **Zouave** improviser known as **Boris** —
resourceful under constraint, chain-minded, wipe-and-continue. Teaching rhythm
for the compile loop: **Load → Roll → Ignite → Reset** (see
[system/10-name-and-metaphor.md](10-name-and-metaphor.md)). Narrative only; not
affiliated with any commercial tobacco or rolling-paper brand.

## What Boris is for (v0.1)

- Compile a markdown content tree into validated **JSON IR** (manifest, graph, report)
- Model content as a **Trunk and Satellite graph** (relational foreign keys)
- Support a **closed frontmatter grammar** (not general YAML)
- Optionally export an **LLM-friendly RAG corpus** under `rag/`
- Keep hard constraints: Zig core, in-process Apex when rendering, no Node SSG stack

## Implemented beyond default IR (library / flags / tests)

- **Aside** tokenizer on the shared compile path (`ECOMPONENT` on failure)
- Optional RAG corpus with `:::kind` **export** blocks for parsed Asides
- Experimental HTML: Apex + Aside stream + Whiteboard + layout splice to `dist/`

Normative IR contracts: `docs/contracts/`. Narrative seeds here must not
overclaim untested guarantees (see STATUS and RELEASE-GATE).

## Non-goals

- Boris does **not** spawn a child process per page for markdown
- Boris does **not** require Node, React, or a JS bundler to produce artifacts
- Boris does **not** invent branded names for ordinary docs features (use Aside, admonition, component)
- Boris does **not** emit standalone fragment pages for normal asides
- The first production shape is a **single-threaded monolith** (stable before concurrency)
- v0.1 does **not** claim full YAML, cross-OS bit-identical IR without multi-OS CI, or atomic IR replacement on all platforms

## Repository layout (mental model)

| Path | Role |
|------|------|
| `content/` | Author source markdown (+ optional registered components) |
| `layouts/main.html` | Site chrome with a single `{{content}}` splice marker (HTML path) |
| `src/` | Zig compiler (pipeline IR path + optional HTML/RAG modules) |
| `vendor/apex/` | C-ABI markdown engine linked into the Boris binary |
| `.boris/` | Generated IR (default CLI) |
| `dist/` | Generated HTML (experimental; not default CLI) |
| `docs/rag/system/` | Curated system knowledge seeds for the RAG exporter |
| `docs/contracts/` | Normative IR / diagnostics / fixtures |
| `rag/` | Generated LLM-ready corpus (upload this tree) |

## How to run

```bash
zig build          # build the boris binary
zig build run      # content compiler → .boris/
zig build rag      # export RAG corpus (boris --rag)
zig build test     # unit + fixture + harness + fuzz
```

Useful flags:

- `--input=DIR` / `--out=DIR` — IR path (defaults `content` / `.boris`)
- `--rag` / `--rag-dir=PATH` — RAG-only export (implies no IR; not HTML+RAG)
- `--no-rag` — explicit IR-only (default)
- `--quiet` — less progress logging

## One-sentence summary for retrieval

Boris v0.1 is a Zig content compiler (named for the folk Zouave improviser Boris) that **loads** Markdown under `content/`, **rolls** a Trunk/Satellite graph, **ignites** deterministic JSON under `.boris/` (optional RAG pack), and **resets** page scratch on the experimental HTML path; Apex assembly remains in-tree, not the default CLI.
