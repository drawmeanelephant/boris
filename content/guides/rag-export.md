---
title: AI & Machine Outputs
parent: guides/overview
status: published
tags: [guides, rag, ai, ir, llms]
---

# AI & Machine Outputs (RAG, IR, Context, llms.txt)

Boris is built from the ground up for both human readers and AI agents. From a single validated content graph, Boris emits native machine formats without web scraping or HTML parsing.

<Aside kind="info">

Machine exports share the same frozen, validated Trunk/Satellite graph model as
HTML. They are separate invocations, so generate the editions from the same
source revision when you need them aligned.

</Aside>

---

## Native Machine Export Modes

| Export Mode | Command Flag | Output Location | Target Consumer |
|---|---|---|---|
| **JSON IR** | `--out <dir>` | chosen `--out` directory | Programmatic tools, graph analyzers, documentation linters |
| **RAG Corpus** | `--rag --rag-dir <dir>` | chosen `--rag-dir` directory | Retrieval pipelines and vector database indexers |
| **AI Context Bundle** | `--context --context-dir <dir>` | chosen `--context-dir` directory | Single-pass prompt context windows |
| **`llms.txt` Index** | `--llms --llms-path <path>` | chosen `--llms-path` | Lightweight machine discovery |

---

## Machine Export Specimen

Here is how a source page is represented across the 4 native machine export formats:

### 1. Source Markdown (`content/guides/asides.md`)
```markdown
---
title: Asides & Admonitions
parent: guides/overview
status: published
summary: Short source summaries are optional unless published_at is set.
---
<Aside kind="tip">

Use `boris validate` before publishing.

</Aside>
```

### 2. JSON IR Record (`dist/.boris/manifest.json`)
```json
{
  "entity_id": "guides/asides",
  "title": "Asides & Admonitions",
  "parent": "guides/overview",
  "status": "published"
}
```

### 3. RAG Corpus Record (`dist/rag/catalog.jsonl`)
```json
{"entity_id":"guides/asides","title":"Asides & Admonitions","path":"content/pages/guides/asides.md","status":"published"}
```

### 4. RAG Body Representation (`dist/rag/content/pages/guides/asides.md`)
```markdown
:::tip
Use `boris validate` before publishing.
:::
```

### 5. `llms.txt` Entry (`dist/llms.txt`)
```text
  - [Asides & Admonitions](/guides/asides.html): Semantic callout blocks in Boris
```

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
- `bundle.md` — All published pages merged in canonical entity-ID order with clear section headers.
- `manifest.json` — Schema specifications, provenance digest, page and relationship counts, and artifact paths.

---

## 4. Standard `llms.txt`

Generates a hierarchical Markdown index conforming to the `llms.txt` standard for AI crawlers:

```bash
./zig-out/bin/boris --llms --llms-path dist/llms.txt
```

---

## Complete Multi-Output Generation Script

To generate HTML and all 4 machine formats cleanly in one scripted workflow against one source revision:

```bash
# HTML site; the compiler emits the rendered search artifact for this build.
./zig-out/bin/boris build --theme examples/prototype-corporate --html-dir dist --quiet

# Machine artifacts, each from the same source revision.
./zig-out/bin/boris build --rag --rag-dir dist/rag --quiet
./zig-out/bin/boris build --out dist/.boris --quiet
./zig-out/bin/boris build --llms --llms-path dist/llms.txt --quiet
./zig-out/bin/boris build --context --context-dir dist/context --quiet
```

---

## Next Steps

- [[reference/outputs|Outputs Specification]] — Detailed JSON schemas for IR, RAG, and Context Bundles.
- [[reference/commands|CLI Reference]] — Full list of flags for all machine output modes.
