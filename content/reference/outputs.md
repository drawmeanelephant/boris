---
title: Outputs and Artifacts
parent: reference
status: published
tags: [reference, outputs]
---

# Outputs and Artifacts

One validated content graph can serve readers, build tools, and retrieval
systems. Pick the output for the job; Boris does not hide several unrelated
artifacts behind one ambiguous command.

| Output | Command | Use it when |
|---|---|---|
| Static HTML | `boris` | You want a normal documentation site under `dist/` |
| JSON IR | `boris --out .boris` | A tool needs nodes, edges, reverse dependencies, and diagnostics |
| RAG corpus | `boris --rag` | You need page-sized, provenance-aware retrieval material |
| Context Bundle | `boris --context` | You need a smaller, scoped bundle for an AI workflow |
| `llms.txt` | `boris --llms` | You want lightweight machine discovery of the documentation |

## HTML is the default

HTML carries the reader experience: navigation comes from the validated graph;
breadcrumbs show the parent chain; the page outline comes from rendered
headings; includes and wiki-links resolve before Apex renders Markdown.

```bash
./zig-out/bin/boris --html-dir public --incremental --jobs 4
```

The result is static files. Host `dist/` (or your chosen directory) with any
ordinary static host; Boris does not require an embedded server or client
framework.

## JSON IR is the integration surface

```bash
./zig-out/bin/boris --out .boris
```

The directory includes `manifest.json`, `graph.json`, and `build-report.json`.
Use it for automation or editor integrations that need the frozen graph,
dependency edges, and structured diagnostics. Its schema is versioned; consume
the documented schema rather than re-parsing frontmatter yourself.

## RAG and Context are deliberate export packages

```bash
./zig-out/bin/boris --rag --rag-dir uploads/boris-rag
./zig-out/bin/boris --context --context-dir uploads/boris-context
```

Both validate the entire graph before creating a new published tree. RAG packs
page segments, graph material, catalog metadata, and curated system seeds.
Context Bundles are the scoped, provenance-oriented companion. Neither output
turns Boris into a hosted AI service; they are local files you can inspect
before sharing.

See [[guides/rag-export|RAG Export Packaging]] for upload parts, scoping, and
the authoring/export distinction for Asides.
