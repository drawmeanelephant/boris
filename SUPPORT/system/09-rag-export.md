---
rag_id: system/rag-export
rag_path: system/09-rag-export.md
category: system
tags: [rag, llm, grok, gemini, corpus, upload]
related:
  - system/00-overview.md
  - system/04-components-and-admonitions.md
  - system/08-build-cli-and-layout.md
  - INDEX.md
  - UPLOAD-GUIDE.md
---

# RAG export system

Boris can generate a **Retrieval-Augmented Generation corpus**: a tree of markdown files with stable paths, YAML frontmatter, cross-links, and catalogs designed for upload into chat LLM knowledge bases (Grok, Gemini, NotebookLM-style tools, etc.).

## Output root

Default: `rag/`

```text
rag/
  INDEX.md                 # master map — start here in a chat
  UPLOAD-GUIDE.md          # how to upload / query
  catalog.jsonl            # one JSON object per document (tooling)
  system/                  # how Boris works
  content/
    pages/                 # site content, path-mirrored (asides inlined)
  graph/
    entity-catalog.md      # all page entities + roles
    relations.md           # trunk → satellites edges
```

## Path design principles (LLM-friendly)

1. **Stable, hierarchical paths** — mirror content entity ids (`content/pages/guides/intro.md`)
2. **Self-contained segments** — each file restates entity id, role, parent, source path
3. **Machine frontmatter** — `rag_id`, `rag_path`, `category`, `tags`, `related`, `entity_id`
4. **Human titles first** — H1 is readable; metadata is in YAML
5. **Separate system vs content** — architecture questions hit `system/`; site copy hits `content/`
6. **Graph docs** — relations are explicit files so retrieval does not require scanning everything
7. **Asides stay on the page** — no one-output-document-per-callout rule

## Segment categories

| category | Meaning |
|----------|---------|
| `system` | Compiler/architecture knowledge |
| `content` | Author page body + metadata (asides inlined in Body) |
| `graph` | Catalogs and edges |
| `meta` | Index / upload guides |

## Generation rules

- System docs are seeded from `docs/rag/system/*.md` and normalized into `rag/system/`
- Content pages are re-read and parsed; Body includes asides as `:::kind` blocks
- `catalog.jsonl` lists every written document for bulk upload scripts
- `INDEX.md` is always regenerated last so it reflects the full tree
