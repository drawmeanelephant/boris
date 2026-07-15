---
title: RAG Export Packaging
parent: guides/overview
status: published
tags: [rag, ai]
---
# RAG Export Packaging

Boris can produce an AI-ready product RAG (Retrieval-Augmented Generation) corpus.

## Generating the Corpus

<Aside kind="danger">
**There is no `zig build rag` step.** This was an old myth.
</Aside>

To generate the RAG corpus, simply use the `--rag` flag:

```bash
./zig-out/bin/boris --rag --quiet
```

This generates output in the `rag/` directory (or wherever `--rag-dir` specifies).

## Output Shape

The generated corpus flattens the Trunk/Satellite graph into LLM-friendly chunks and injects export-only `:::kind` metadata and `parent_entry` fields into the catalog. 

These outputs are *strictly for export* and should **never** be copied back into the `content/` source directory. The authoring frontmatter contract is completely separate from the RAG export schema.
