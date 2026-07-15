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

**Write Markdown. Run `boris`. Get a docs site** under `dist/`. Same binary can
also emit validated JSON IR (`--out`) or an LLM knowledge pack (`--rag`).

Boris is a Zig documentation compiler — not a Node/React SSG. Teaching rhythm
(narrative only): **Load → Roll → Ignite → Reset** (see
[system/10-name-and-metaphor.md](10-name-and-metaphor.md)). Named for the folk
**Zouave** improviser known as **Boris**; not affiliated with any commercial
tobacco or rolling-paper brand.

## What you get

- A **static docs site** from Markdown (default CLI → `dist/`)
- **Real ApexMarkdown Unified** (tables, footnotes, modern constructs) in-process
- **Callouts on the page** via constrained `<Aside>` (document order)
- A **Trunk/Satellite graph** that fails loud when parents/cycles break
- Optional **JSON IR** and **deterministic RAG** from the same content tree
- **Lean rebuilds** when you opt in: skip unchanged pages, parallel page work,
  stream layout+body instead of one giant HTML string (design intent; measure
  your tree before quoting numbers)

## How it works (short)

Discover content → closed frontmatter → graph validate → emit HTML, IR, or RAG.
Normative detail: `docs/contracts/`. Living phase: `docs/STATUS.md`. Historical
campaign notes may live under `archive/` and are not required reading.

Narrative seeds must not overclaim untested guarantees (see STATUS and
RELEASE-GATE).

## Non-goals

- Boris does **not** spawn a child process per page for markdown
- Boris does **not** require Node, React, or a JS bundler to produce artifacts
- Boris does **not** invent branded names for ordinary docs features (use Aside, admonition, component)
- Boris does **not** emit standalone fragment pages for normal asides
- IR/RAG and pre-render coordination stay sequential; only HTML page render
  may use bounded `--jobs` workers under documented isolation rules
- Boris does **not** claim full YAML, unrestricted MDX, cross-OS bit-identical IR
  without multi-OS CI, or atomic publish on every volume

## Repository layout (mental model)

| Path | Role |
|------|------|
| `content/` | Author source markdown (+ optional registered components) |
| `layouts/main.html` | Site chrome with a single `{{content}}` splice marker (HTML path) |
| `src/` | Zig compiler (HTML path + IR + RAG modules) |
| `vendor/apex/` | Host C-ABI adapter linked into the Boris binary |
| `dist/` | Generated HTML (**default** CLI output) |
| `.boris/` | Generated IR (via `--out` / `--no-rag`) |
| `docs/rag/system/` | Curated system knowledge seeds for the RAG exporter |
| `docs/contracts/` | Normative IR / HTML / diagnostics / fixtures |
| `rag/` | Generated LLM-ready corpus (upload this tree) |

## How to run

```bash
zig build          # build the boris binary
zig build run      # HTML site → dist/ (default)
zig build run -- --out=.boris   # JSON IR only
zig build test     # unit + fixture + harness + fuzz
```

Useful flags:

- *(none)* / `--html` / `--html-dir=DIR` / `--target NAME=DIR` — HTML site mode
- `--out=DIR` / `--no-rag` — IR path (defaults `content` / `.boris`)
- `--rag` / `--rag-dir=PATH` — RAG-only export (implies no IR; not HTML+RAG)
- `--jobs N` / `--watch` / `--incremental` — HTML scale-out / rebuild controls
- `--quiet` — suppress progress + diagnostic stderr (exit codes/artifacts unchanged)

## One-sentence summary for retrieval

Boris is a Zig documentation compiler that turns Markdown into a validated
Trunk/Satellite site under `dist/` by default (or JSON IR / RAG on request),
with real ApexMarkdown Unified rendering and constrained in-page Asides.
