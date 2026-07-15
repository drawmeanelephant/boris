---
rag_id: meta/upload-guide
rag_path: UPLOAD-GUIDE.md
category: meta
tags: [upload, grok, gemini, llm, rag]
related:
  - INDEX.md
---

# Upload guide — Grok, Gemini, and similar chat LLMs

## What to upload

Upload the **entire** generated RAG directory. Prefer folder upload when
the product supports it.

Minimum useful set if you must subset:

1. `INDEX.md` (always)
2. All of `system/` (Boris behavior)
3. All of `content/` (site knowledge)
4. All of `graph/` (relations)

Optional for scripts: `catalog.jsonl` and `catalog_meta.json` (machine
files; not catalog rows).

## Regenerating this corpus

```bash
zig build run -- --input content --rag
zig build run -- --input content --rag-dir ./uploads/boris-rag
```

## Integrity notes

- Paths inside documents are logical RAG paths (not OS-absolute).
- Content segments mirror `entity_id` (`guides/intro` → `content/pages/guides/intro.md`).
- Graph-dependent files are published only after shared `graph.validate` succeeds.
- Parsed `<Aside>` callouts appear as `:::kind` export blocks (not authoring syntax).
