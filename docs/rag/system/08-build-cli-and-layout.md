---
rag_id: system/build-cli-and-layout
rag_path: system/08-build-cli-and-layout.md
category: system
tags: [cli, build, layout, flags, zig]
related:
  - system/00-overview.md
  - system/01-architecture-pipeline.md
  - system/04-components-and-admonitions.md
  - system/07-zero-copy-assembly.md
  - system/09-rag-export.md
---

# Build system, CLI, and layout contract

## Zig package

- `build.zig` / `build.zig.zon` — package name `boris`, minimum Zig `0.16.0`
- Executable artifact: `boris`
- Steps:
  - `zig build` — compile/install
  - `zig build run -- …` — product CLI (IR default; `--rag` / `--rag-dir` for RAG)
  - `zig build test` — unit + hardening + fuzz tests
  - `zig build test-apex-hostile` / `zig build test-apex-sanitize` — Apex extras
  - `zig build source-rag` — source-code pack tool (not product RAG)

**Workshop analogy:** one foreman and one workbench.  
**Invariant:** single-threaded product path; no worker pools or shared mutable
graph state across threads.

## Layout contract

File: `layouts/main.html`

Must contain exactly one splice marker:

```html
{{content}}
```

Everything before becomes `prefix`; everything after becomes `suffix`. Both are
`[]const u8` views into the loaded template buffer owned by a `Layout` whose
lifetime must exceed all page writes. Missing or duplicate markers are hard
errors at layout load (before content scan).

Admonition styles use classes such as `.admonition`, `.admonition--tip`,
`.admonition__title`.

## Content contract

- Root: `content/` (override with `--input=DIR`)
- Page files: `*.md` or `*.mdx`
- Optional frontmatter between `---` fences
- Optional registered components in body, currently:

```html
<Aside kind="tip" id="optional-anchor">…</Aside>
```

## CLI modes (v0.1 product surface)

| Mode | Flags | Writes |
|------|-------|--------|
| **IR (default)** | *(none)* or `--no-rag` | JSON under `--out` (default `.boris`) |
| **RAG-only** | `--rag` and/or `--rag-dir=DIR` | Corpus under RAG dir (default `rag/`) |

**Decision:** `--rag-dir=DIR` **implies RAG-only**. It is **not** “HTML plus RAG”
and **not** “IR plus RAG”. HTML site generation remains an in-tree experiment
(`compile` / `assemble`) and is not the default CLI path.

`--out` applies **only** to the IR path. An explicit `--out=…` combined with
`--rag` or `--rag-dir` is a **usage error** (exit 2) — never silently ignored.
Use `--rag-dir` to choose the RAG corpus directory.

## CLI flags

| Flag | Effect |
|------|--------|
| `--input=DIR` | Content root (default: `content`) |
| `--out=DIR` | IR artifact directory (default: `.boris`); IR path only |
| `--rag` | RAG export only (default dir: `rag/`) |
| `--no-rag` | Explicit IR-only (default; mutually exclusive with `--rag` / `--rag-dir`) |
| `--rag-dir=DIR` | RAG output directory (**implies RAG-only**) |
| `--quiet` | Less progress logging |
| `-h`, `--help` | Print usage and exit `0` **without** scanning content |

Malformed empty values for `--input=`, `--out=`, or `--rag-dir=` are usage
errors (exit 2).

## Exit codes

| Code | Meaning |
|-----:|---------|
| 0 | Success |
| 1 | Content / validation error |
| 2 | Usage / flag error |
| 3 | I/O / system error |

## Example invocations

```bash
zig build run
zig build run -- --input=content --out=.boris
zig build run -- --no-rag
zig build run -- --rag
zig build run -- --rag-dir=./uploads/boris-rag
zig build rag
zig build rag -- --rag-dir=./uploads/boris-rag
zig build rag -- --help
```
