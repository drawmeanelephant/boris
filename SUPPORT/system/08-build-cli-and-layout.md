---
rag_id: system/build-cli-and-layout
rag_path: system/08-build-cli-and-layout.md
category: system
tags: [cli, build, layout, flags, zig]
related:
  - system/00-overview.md
  - system/01-architecture-pipeline.md
  - system/04-components-and-admonitions.md
  - system/09-rag-export.md
---

# Build system, CLI, and layout contract

## Zig package

- `build.zig` / `build.zig.zon` — package name `boris`, minimum Zig `0.16.0`
- Executable artifact: `boris`
- Steps:
  - `zig build` — compile/install
  - `zig build run` — run with optional args after `--`
  - `zig build rag` — RAG export convenience step
  - `zig build test` — unit tests

## Layout contract

File: `layouts/main.html`

Must contain exactly one splice marker:

```html
{{content}}
```

Everything before becomes `prefix`; everything after becomes `suffix`. Missing marker is a hard error at startup.

Admonition styles use classes such as `.admonition`, `.admonition--tip`, `.admonition__title`.

## Content contract

- Root: `content/`
- Page files: `*.md` or `*.mdx`
- Optional frontmatter between `---` fences
- Optional registered components in body, currently:

```html
<Aside kind="tip" id="optional-anchor">…</Aside>
```

## CLI flags (boris)

| Flag | Effect |
|------|--------|
| *(default)* | Compile HTML to `dist/` **and** export RAG to `rag/` |
| `--rag` | RAG export only (still scans/parses content) |
| `--no-rag` | HTML compile only |
| `--rag-dir=DIR` | Write corpus under `DIR` instead of `rag` |
| `--quiet` | Less whiteboard / progress logging |

## Example invocations

```bash
zig build run
zig build run -- --rag
zig build run -- --no-rag
zig build run -- --rag-dir=./uploads/boris-rag
zig build rag
```
