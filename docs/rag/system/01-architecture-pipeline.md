---
rag_id: system/architecture-pipeline
rag_path: system/01-architecture-pipeline.md
category: system
tags: [architecture, pipeline, phases, compile]
related:
  - system/00-overview.md
  - system/02-data-model-page.md
  - system/04-components-and-admonitions.md
  - system/05-memory-whiteboard.md
  - system/06-apex-native-engine.md
  - system/07-zero-copy-assembly.md
  - system/10-name-and-metaphor.md
---

# Architecture and compile pipeline

Boris is built in phased layers. The runtime remains a **single-threaded monolith**
so memory and ordering stay predictable.

## Teaching rhythm: Load · Roll · Ignite · Reset

Narrative names for the same work (not CLI flags). Full lore:
[system/10-name-and-metaphor.md](10-name-and-metaphor.md).

| Beat | Meaning | v0.1 IR (default) | HTML path (experimental) |
|------|---------|-------------------|--------------------------|
| **Load** | Gather sources in deterministic order | `discover` | `scanner` + identity |
| **Roll** | Shape frontmatter, body, graph | frontmatter + `graph.validate` freeze | `parser` + graph |
| **Ignite** | Emit / render / package | JSON under `.boris/` (+ optional RAG) | Apex + `assemble` → `dist/` |
| **Reset** | Drop page scratch; next unit clean | finish emit without leftover soup | whiteboard `arena.reset` |

```text
LOAD ──► ROLL ──► IGNITE ──► RESET ──► (next page / next build unit)
```

## Two product surfaces

| Surface | Default? | Modules | Output |
|---------|----------|---------|--------|
| **Content compiler (v0.1)** | **yes** | `pipeline`, `discover`, `frontmatter`, `graph`, `diag`, `json_out` | `.boris/{manifest,graph,build-report}.json` |
| **RAG export** | opt-in (`--rag`) | `scanner`, `parser`, `rag` (+ shared `graph.validate`) | `rag/` corpus |
| **HTML site** | experimental | `scanner`, `parser`, `apex`, `aside`, `compile`, `assemble` | `dist/` (unit-tested; not default CLI) |

## v0.1 IR pipeline (default)

```text
main
 └─ pipeline.run
     ├─ discover   (.md/.mdx; sort by entity_id)     # LOAD
     ├─ frontmatter (closed grammar; parent key only) # ROLL
     ├─ graph.validate + freeze                       # ROLL
     └─ emit       manifest.json, graph.json, …       # IGNITE
     # RESET: no per-page whiteboard on this path yet; emit is the clean finish
```

## Experimental HTML pipeline (modules present)

| Phase | Beat | Module | Responsibility |
|------:|------|--------|----------------|
| 1 | Load | `scanner.zig` + `page.zig` | Walk content; build `Page` list |
| 2 | Roll | `parser.zig` | Frontmatter + ordered body segments |
| 3 | Ignite | `apex.zig` + `vendor/apex/` | In-process markdown → HTML via C ABI |
| 4 | Ignite + Reset | `compile.zig` + `aside.zig` | Whiteboard arena loop; `free_all` per page |
| 5 | Ignite | `assemble.zig` | Layout prefix \| body \| suffix to `dist/` |

## Important invariants

- **One content walk** at discover/scan time — no repeated recursive discovery mid-compile.
- **No process spawn for markdown** — Apex is linked when used.
- **Document allocations die with the whiteboard** (HTML path) — only promoted metadata survives.
- **Components stay in document order** — no separate fragment pages for normal asides.
- **Assembly never concatenates** layout + body into a new mega-string; it writes three slices (HTML path).
- **Graph validation is shared** — IR and RAG both call `graph.validate` before graph-dependent emit.

## Entry point facts

- Language: Zig **0.16** (`build.zig.zon` `minimum_zig_version = "0.16.0"`; CI pins the same)
- I/O: `std.Io` (`Dir`, `File`, walkers require `iterate: true`)
- Lists: unmanaged `std.ArrayList`
- Binary name: `boris` (`zig-out/bin/boris`)
