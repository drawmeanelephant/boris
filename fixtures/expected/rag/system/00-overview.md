---
rag_id: system/overview
rag_path: system/00-overview.md
category: system
tags: [boris, overview, content-compiler, zig]
---


# Boris overview

Boris is a **Zig content compiler for Markdown documentation** that is growing
into a full Apex-native static site generator. The **default product surface**
is: discover content → bounded frontmatter → Trunk/Satellite graph validation →
HTML site under `dist/` (Apex + Whiteboard + layout splice). Optional: JSON IR
via `--out` / `--no-rag`, or an LLM RAG corpus via `--rag` / `--rag-dir`.

The project is named for the folk **Zouave** improviser known as **Boris** —
resourceful under constraint, chain-minded, wipe-and-continue. Teaching rhythm
for the compile loop: **Load → Roll → Ignite → Reset** (see
[system/10-name-and-metaphor.md](10-name-and-metaphor.md)). Narrative only; not
affiliated with any commercial tobacco or rolling-paper brand.

## What Boris is for

- Build a markdown documentation site into HTML under `dist/` (default CLI)
- Compile the same tree into validated **JSON IR** via `--out` (manifest, graph, report)
- Model content as a **Trunk and Satellite graph** (relational foreign keys)
- Support a **closed frontmatter grammar** (not general YAML)
- Optionally export an **LLM-friendly RAG corpus** under `rag/`
- Keep hard constraints: Zig core, in-process Apex when rendering, no Node SSG stack

## Implemented product surface

- **Aside** tokenizer on the shared compile path (`ECOMPONENT` on failure)
- Optional RAG corpus with `:::kind` **export** blocks for parsed Asides
- **HTML default:** Apex + Aside stream + Whiteboard + layout splice to `dist/`
  (and named multi-target roots), with `--incremental`, `--jobs`, and `--watch`
- Apex engine is in-process C ABI via **ApexMarkdown Unified** (Feature 1)

Normative contracts: `docs/contracts/`. Narrative seeds here must not
overclaim untested guarantees (see STATUS and RELEASE-GATE).

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

Boris is a Zig documentation compiler (named for the folk Zouave improviser Boris) that **loads** Markdown under `content/`, **rolls** a Trunk/Satellite graph, **ignites** an HTML site under `dist/` by default (or JSON IR / RAG on request), and **resets** page scratch on the HTML path with real ApexMarkdown Unified rendering.
