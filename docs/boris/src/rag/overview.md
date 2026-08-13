---
title: "`src/rag.zig` overview"
id: docs/boris/src/rag
status: draft
tags: [boris, zig, source-reference, rag]
---

# `src/rag.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/rag/surface-and-execution|Surface and execution]]
* [[docs/boris/src/rag/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/rag/review-state|Review state]]

## Executive summary

`src/rag.zig` is the public entry point for Boris's optional RAG (Retrieval-Augmented Generation) corpus export, designated milestone 7 in the module's own doc-comment. It orchestrates the full pipeline from shared content compilation through output of a structured, deterministic document tree suitable for upload to a chat-LLM knowledge base such as Grok or Gemini.

The file is exclusively a production module, not a test harness. It contains six embedded `test` declarations that exercise its own internal helpers and its `run` function end-to-end; these tests are compiled and executed by the normal `zig build test` suite. There is no separate hostile-environment or ABI-stress role; the file operates entirely within safe Zig memory and filesystem abstractions.

Its architectural purpose is to re-use the existing `pipeline.compile` path (scanner → parser → PageDb → `graph.validate` → freeze) without inventing a second parser or graph validator, then to drive the rendering functions in `src/rag_emit.zig` to produce a fixed output tree under a staging directory before atomically publishing it. The strict gate is: if `pipeline.compile` returns `ok == false`, no corpus is written and any prior output directory is left untouched. Content validity is a necessary precondition for every published artifact.

The output tree is normatively described in the module doc-comment and in `docs/contracts/rag-export.md` (referenced but not inspected here). Produced artifacts are: `INDEX.md`, `UPLOAD-GUIDE.md`, `catalog.jsonl`, `catalog_meta.json`, `system/**` (seeded from an optional curated directory), `content/pages/**` (path-mirrored page segments), `graph/entity-catalog.md`, and `graph/relations.md`. All bytes are intended to be deterministic: the module explicitly excludes timestamps, absolute paths, hostnames, random values, and hash-map or filesystem-walk order from emitted bytes, using stable sorts throughout.

The module does not perform HTML rendering and does not invoke the Oliver-backed rendering seam. It is entirely decoupled from `src/render.zig` and the HTML rendering path.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with embedded unit and integration tests |
| Conceptual domain | RAG corpus export; deterministic document serialization; safe filesystem publish |
| Build or test root | Not a build root; compiled as part of the main `boris` executable and the standard test step |
| Production runtime dependency | Yes — linked into the product binary; invoked when `--rag` or `--rag-dir` is passed on the CLI |
| Expected execution command | `zig build test` (for the embedded tests); `zig build run -- --input content --rag` (production use) |
| Main collaborators | `src/pipeline.zig` (shared compile), `src/rag_emit.zig` (byte renderers), `src/aside.zig` (component tokenizer), `src/parser.zig`, `src/identity.zig`, `src/graph.zig`, `src/textile.zig`, `src/diag.zig` |
| Documentation depth warranted | Medium-high — complex multi-phase publish logic and determinism guarantees warrant detailed treatment |

## Role in the Boris architecture

`src/rag.zig` sits in the output-emission layer of the Boris pipeline, parallel to the IR emission path in `src/pipeline.zig`. The product binary exposes it through a `--rag` / `--rag-dir` CLI flag; the main entrypoint calls `rag.run` instead of `pipeline.run` when that flag is active.

The file is **linked into the production binary** and is **not** compiled only for tests. Its `pub fn run` is the sole public API surface.

Relative to `src/render.zig`: `src/rag.zig` has no dependency on it. Zig-internal Markdown manipulation (H1 stripping, H1 demotion, aside-to-directive conversion) is performed entirely in pure Zig helpers. The Oliver renderer is irrelevant to the RAG path.

Relative to `src/rag_emit.zig`: `src/rag.zig` owns the orchestration layer — file discovery, ordering, staging directory management, catalog accumulation, and publish mechanics. `src/rag_emit.zig` owns the byte-level rendering of individual documents and catalog records, and is stateless with respect to the filesystem. The split means that `rag_emit.zig` can be tested independently of I/O.

Relative to the normal test suite: the five integration tests in `src/rag.zig` are part of the regular `zig build test` run. They create temporary directories under `.zig-cache/tmp/`, write fixture content using inline multiline string literals, call `rag.run` or its sub-functions, and assert on the file tree produced. There is no separate build step or separate test binary for this file.
