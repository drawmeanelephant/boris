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
---

# Architecture and compile pipeline

Boris is built in phased layers (skateboard → bicycle → car). Each phase is a module with a single responsibility. The runtime remains a **single-threaded monolith** so memory and ordering stay predictable.

## Phase map

| Phase | Module | Responsibility |
|------:|--------|----------------|
| 1 | `src/scanner.zig` + `src/page.zig` | Walk `content/` once; build `Page` list (paths, entity ids) |
| 2 | `src/parser.zig` | Frontmatter + ordered body segments (markdown / registered components) |
| 3 | `src/apex.zig` + `vendor/apex/` | In-process markdown → HTML via C ABI |
| 4 | `src/compile.zig` + `src/aside.zig` | Whiteboard arena loop: read → parse → render segments → write → reset |
| 5 | `src/assemble.zig` | Load layout once; stream prefix + HTML + suffix to `dist/` |
| 6 | `src/rag.zig` | Export LLM-friendly RAG segments for system + content + graph |

## Runtime control flow

1. `main` receives `std.process.Init` (Zig 0.16): `gpa`, process `arena`, `io`.
2. Load `layouts/main.html` once into cold storage; split on `{{content}}`.
3. `PageDb.init` + `scanner.scanFromCwd` — exact one walk of `content/`.
4. For each page in order:
   - Read source bytes into the **document arena**
   - Parse frontmatter and body into an ordered **segment stream**
   - Render markdown segments via Apex; render registered components (asides) to HTML
   - Stream one ordered HTML body through the layout writer into `dist/`
   - `arena.reset(.free_all)` — wipe document scratch
5. Export RAG corpus (unless `--no-rag`): system docs, content pages (asides inlined), graph, catalogs.

## Important invariants

- **One content walk** at scan time — no repeated recursive discovery mid-compile.
- **No process spawn for markdown** — Apex is linked; rendering is a function call.
- **Document allocations die with the whiteboard** — only graph metadata (entity id, title, parentEntry, paths) is promoted to the long-lived page arena.
- **Components stay in document order** — no separate fragment pages for normal asides.
- **Assembly never concatenates** layout + body into a new mega-string; it writes three slices.

## Module dependency sketch

```
main
 ├─ assemble   (layout load / split)
 ├─ scanner    (content walk → PageDb)
 ├─ compile
 │   ├─ parser
 │   ├─ aside
 │   ├─ apex
 │   └─ assemble.writePage
 └─ rag
     ├─ parser (re-read content for self-contained segments)
     └─ docs/rag/system/* (seed knowledge)
```

## Entry point facts

- Language: Zig **0.16**
- I/O: `std.Io` (`Dir`, `File`, walkers require `iterate: true`)
- Lists: unmanaged `std.ArrayList` (`.empty`, `append(gpa, item)`)
- Binary name: `boris` (`zig-out/bin/boris`)
