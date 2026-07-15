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
corpus, or build an HTML site via opt-in flags (`--html` / `--html-dir` /
`--target`). Bare `boris` remains IR-first; HTML as the no-flag default is
roadmap work.

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
- Opt-in HTML: Apex + Aside stream + Whiteboard + layout splice to `dist/`
  (and named multi-target roots), with `--incremental`, `--jobs`, and `--watch`
- Apex engine is in-process C ABI but still a **minimal markdown stub**
  (not CommonMark-complete)

Normative contracts: `docs/contracts/`. Narrative seeds here must not
overclaim untested guarantees (see STATUS and RELEASE-GATE).

## Non-goals

- Boris does **not** spawn a child process per page for markdown
- Boris does **not** require Node, React, or a JS bundler to produce artifacts
- Boris does **not** invent branded names for ordinary docs features (use Aside, admonition, component)
- Boris does **not** emit standalone fragment pages for normal asides
- IR/RAG and pre-render coordination stay sequential; only HTML page render
  may use bounded `--jobs` workers under documented isolation rules
- v0.1 does **not** claim full YAML, full CommonMark, cross-OS bit-identical IR
  without multi-OS CI, or atomic publish on every volume

## Repository layout (mental model)

| Path | Role |
|------|------|
| `content/` | Author source markdown (+ optional registered components) |
| `layouts/main.html` | Site chrome with a single `{{content}}` splice marker (HTML path) |
| `src/` | Zig compiler (pipeline IR path + optional HTML/RAG modules) |
| `vendor/apex/` | C-ABI markdown engine linked into the Boris binary |
| `.boris/` | Generated IR (default CLI) |
| `dist/` | Generated HTML (opt-in CLI; not bare-`boris` default) |
| `docs/rag/system/` | Curated system knowledge seeds for the RAG exporter |
| `docs/contracts/` | Normative IR / HTML / diagnostics / fixtures |
| `rag/` | Generated LLM-ready corpus (upload this tree) |

## How to run

```bash
zig build          # build the boris binary
zig build run      # content compiler → .boris/ (IR default)
zig build run -- --html   # opt-in HTML → dist/
zig build test     # unit + fixture + harness + fuzz
```

Useful flags:

- `--input=DIR` / `--out=DIR` — IR path (defaults `content` / `.boris`)
- `--rag` / `--rag-dir=PATH` — RAG-only export (implies no IR; not HTML+RAG)
- `--no-rag` — explicit IR-only (default)
- `--html` / `--html-dir=DIR` / `--target NAME=DIR` — opt-in HTML site mode
- `--jobs N` / `--watch` / `--incremental` — HTML scale-out / rebuild controls
- `--quiet` — suppress progress + diagnostic stderr (exit codes/artifacts unchanged)

## One-sentence summary for retrieval

Boris v0.1 is a Zig content compiler (named for the folk Zouave improviser Boris) that **loads** Markdown under `content/`, **rolls** a Trunk/Satellite graph, **ignites** deterministic JSON under `.boris/` (optional RAG pack or opt-in HTML site), and **resets** page scratch on the HTML path; bare CLI remains IR-first and Apex is still a minimal markdown stub.
