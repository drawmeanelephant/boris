---
title: "`src/rag_emit.zig` overview"
id: docs/boris/src/rag_emit
status: draft
tags: [boris, zig, source-reference, rag_emit]
---

# `src/rag_emit.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/rag_emit/surface-and-execution|Surface and execution]]
* [[docs/boris/src/rag_emit/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/rag_emit/review-state|Review state]]

## Executive summary

`src/rag_emit.zig` is a pure, deterministic rendering library that converts frozen, validated Boris content data into the textual artifacts that make up a product RAG (Retrieval-Augmented Generation) corpus. It is the single authoritative place where field order, H1 normalization rules, catalog schema, JSONL line format, graph document structure, and index document layout are defined for downstream LLM upload.

The file deliberately does not walk the filesystem, write files, drive the compilation pipeline, invoke the Apex Markdown engine, or produce any output that depends on non-deterministic inputs such as wall-clock time, absolute hostnames, or iteration order of hash maps. Every public function receives already-parsed, already-validated data—`graph_mod.Node` slices, pre-tokenized `aside.Segment` slices, `CatalogEntry` arrays—and returns a freshly allocated `[]u8` owned by the caller under a single named GPA argument.

The file exists to enforce a strict, versioned contract on the shape of the RAG corpus so that re-runs produce byte-identical output for the same input and so that any regression in field ordering, escaping, or H1 treatment is immediately visible as a test failure rather than a silent change in uploaded content.

The module is invoked from the RAG build pipeline (`rag.zig` or equivalent caller). It is not linked into the HTML rendering path and does not call `apex.render`. It is exercised by the inline test `"catalog JSONL field order and escaping are stable"`, which is the only test embedded in this file. Several of its helpers (`stripLeadingAtxH1`, `demoteAtxH1ToH2`, `renderBody`, `sortCatalogByRagPath`) are private and exercised only indirectly through the public render functions.

The file provides no guarantees about the content of the Markdown body passed to it—it trusts that upstream validation has already accepted or rejected invalid inputs. It makes no safety claim about concurrent access; all functions are single-threaded by design and must be called after the graph is frozen.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library (pure render functions + one embedded unit test) |
| Conceptual domain | RAG corpus emission; deterministic text serialization |
| Build or test root | Not a root; imported by the RAG pipeline module |
| Production runtime dependency | Yes — linked into the `boris` binary via the RAG pipeline |
| Expected execution command | `zig build test` (for embedded test); `zig build run -- --input content --rag` (production invocation) |
| Main collaborators | `src/aside.zig` (Segment, Aside, Details, formatRagDirective, formatDetailsRagDirective), `src/graph.zig` (Node, Role), `src/json_out.zig` (escapeAppend) |
| Documentation depth warranted | Medium-high — stable schema and H1 normalization rules deserve explicit contracts |

***

## Role in the Boris architecture

`rag_emit.zig` sits at the output boundary of the Boris RAG pipeline. Upstream modules—graph validation, Markdown parsing, aside tokenization—must have completed successfully before any function in this file is called. The module receives their outputs as plain Zig slices and structs.

It has no dependency on `src/apex.zig` and does not render Markdown to HTML. The `renderBody` function calls `aside.formatRagDirective` and `aside.formatDetailsRagDirective` for aside/details segments, and calls the private `demoteAtxH1ToH2` and `stripLeadingAtxH1` helpers for markdown segments—none of these invoke the Apex C ABI. This is the correct separation: HTML rendering is for the web build path; RAG emission is text-to-text with structural transformations only.

The file is compiled into the production binary. It is not test-only infrastructure. It is also not a test double or harness; the one inline test validates only the JSONL serializer.

The file does not contain any interaction with the hostile Apex test double (`src/apex_hostile_test.zig`). That boundary is entirely within `src/aside.zig`'s HTML render path (`renderHtml`, `renderDetailsHtml`), which calls `apex.render`. `rag_emit.zig`'s `renderBody` bypasses `apex.render` entirely, making it independent of the Apex ABI contract.

***
