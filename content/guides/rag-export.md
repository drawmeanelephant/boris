---
title: RAG Export Packaging
parent: guides/overview
status: published
tags: [rag, ai]
---

# RAG Export Packaging

Boris can emit a deterministic product **RAG** (retrieval) corpus from the same
content graph used for HTML and IR.

## Generate the corpus

```bash
./zig-out/bin/boris --rag --quiet
./zig-out/bin/boris --rag-dir ./uploads/rag --quiet
```

<Aside kind="danger">

There is **no** `zig build rag` product step. Use `boris --rag` (or
`zig build run -- --rag`).

</Aside>

## Output shape (high level)

Typical tree under `rag/`:

```text
rag/
  INDEX.md
  README.md
  UPLOAD-GUIDE.md
  catalog_meta.json      # format + schema_version + boris_version
  catalog.jsonl          # one row per catalogued page
  content/pages/…        # exported page markdown
  graph/                 # graph snapshot for consumers
  system/                # curated narrative seeds
```

- Shared **graph validation** with IR/HTML: broken parents fail RAG too.
- Catalog may use export field name `parent_entry` for the parent id — that is
  **not** author frontmatter. Author key remains **`parent` only**.
- Asides may appear as `:::kind` in export packaging only.

Never copy export-only field names or `:::kind` authoring back into `content/`.

For day-to-day site builds use bare `boris` → `dist/` (see
[[guides/cli-and-modes|CLI and modes]]). Frontmatter rules:
[[reference/frontmatter]].

Normative contract: `docs/contracts/rag-export.md` in the repository.
