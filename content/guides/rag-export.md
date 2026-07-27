---
title: AI & Machine Outputs
parent: guides/overview
status: published
tags: [guides, rag, ai, ir, llms]
---

# AI & Machine Outputs (RAG, IR, Context, llms.txt)

Boris is built from the ground up for both human readers and AI agents. From a single validated content graph, Boris emits native machine formats without web scraping or HTML parsing.

<Aside kind="info">

**Layer 1 & 3 Summary:** Machine exports share the exact same frozen, validated Trunk/Satellite graph as HTML output. A site that passes `boris check` generates 100% consistent JSON IR, RAG corpora, Context Bundles, and `llms.txt`.

</Aside>

---

## 4 Native Machine Export Modes

| Export Mode | Command Flag | Output Location | Target Consumer |
|---|---|---|---|
| **JSON IR** | `--out <dir>` | `dist/.boris/` | Programmatic tools, graph analyzers, documentation linters |
| **RAG Corpus** | `--rag --rag-dir <dir>` | `dist/rag/` | Vector database indexers, AI retrieval pipelines |
| **AI Context Bundle** | `--context --context-dir <dir>` | `dist/context/` | Single-pass prompt context windows for LLMs |
| **`llms.txt` Index** | `--llms --llms-path <path>` | `dist/llms.txt` | AI web crawlers and standardized agent navigation |

---

## 1. JSON Intermediate Representation (IR)

The JSON IR exports a typed, versioned graph snapshot of your entire documentation suite.

```bash
./zig-out/bin/boris --out dist/.boris
```

### Artifacts generated in `dist/.boris/`:
- `manifest.json` — Build metadata, compiler version, base IR schema version (`0.2.0`), page list.
- `graph.json` — Directed graph of page parent relationships and wiki-link edges.
- `build-report.json` — Build timing, total pages, and validation status.

---

## 2. RAG Corpus Export

The RAG exporter writes clean, frontmatter-enriched Markdown files with a JSONL catalog and graph maps.

```bash
./zig-out/bin/boris --rag --rag-dir dist/rag
```

### Advanced RAG Flags:
- **Scoped Export:** Export only a subset branch:
  ```bash
  ./zig-out/bin/boris --rag --scope guides --rag-dir dist/rag
  ```
- **Size Splitting:** Split large corpora into provider-friendly chunks (e.g. 2MB max per bundle):
  ```bash
  ./zig-out/bin/boris --rag --split-size 2000000 --rag-dir dist/rag
  ```

---

## 3. AI Context Bundle

Combines all pages into a single cohesive Markdown document optimized for LLM context windows.

```bash
./zig-out/bin/boris --context --context-dir dist/context
```

### Generated Files:
- `bundle.md` — All published pages merged in graph-topological order with clear section headers.
- `manifest.json` — Page index and character/word counts.

---

## 4. Standard `llms.txt`

Generates a hierarchical Markdown index conforming to the `llms.txt` standard for AI crawlers:

```bash
./zig-out/bin/boris --llms --llms-path dist/llms.txt
```

---

## Complete Multi-Output Generation Script

To generate HTML and all 4 machine formats cleanly in one build pass:

```bash
# 1. HTML Site
./zig-out/bin/boris --theme examples/prototype-corporate --html-dir dist --quiet

# 2. Client-Side Search Index
zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search

# 3. Machine Artifacts
./zig-out/bin/boris --rag --rag-dir dist/rag --quiet
./zig-out/bin/boris --out dist/.boris --quiet
./zig-out/bin/boris --llms --llms-path dist/llms.txt --quiet
./zig-out/bin/boris --context --context-dir dist/context --quiet
```

---

## Next Steps

- [[reference/outputs|Outputs Specification]] — Detailed JSON schemas for IR, RAG, and Context Bundles.
- [[reference/commands|CLI Reference]] — Full list of flags for all machine output modes.
