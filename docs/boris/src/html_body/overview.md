---
title: "`src/html_body.zig` overview"
id: docs/boris/src/html_body
status: draft
tags: [boris, zig, source-reference, html_body]
---

# `src/html_body.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/html_body/surface-and-execution|Surface and execution]]
* [[docs/boris/src/html_body/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/html_body/review-state|Review state]]

## Executive summary

`src/html_body.zig` is the shared, canonical HTML body rendering pipeline for Boris. It defines the ordered sequence of transformations that converts one parsed Markdown (or Textile) source document into the HTML body string that the assembler writes into a page layout. The module exposes two public functions — `bodyForInput` and `renderSource` — and one public configuration struct, `Options`. The two inline tests exercise diagnostic formatting and end-to-end pipeline ordering.

The file exists because the body-rendering logic was previously duplicated between at least two call sites (`compile.zig`'s HTML publish path and the heading-index path). Extracting it into a shared module enforces a single, documented ordering contract — parse/adapt → include expansion → wiki-link rewrite → content-local asset rewrite → Aside tokenization → Apex/Aside streaming — and eliminates drift between paths that must behave identically.

The system boundary this module protects is the contract between Boris's Zig pipeline stages and the ApexMarkdown C ABI. Everything upstream of the `apex.render` call happens in pure Zig and is fully inspectable; the module never calls `apex.render` on the whole document, only on Markdown-typed segments after Aside tokenization has split the body. This ensures Aside component markup is never passed to the C engine, and Apex is only given clean, pre-validated Markdown slices.

The module is compiled as part of the main product module rooted at `src/main.zig`, and its tests are executed as part of that module's test binary under `zig build test`. It is also reachable from `src/compile.zig` and any module that imports it. The two embedded `test` declarations run within the same binary as the rest of the product unit tests; they require a real filesystem (via `std.testing.io` and `std.testing.tmpDir`) for the pipeline-ordering test. No separate test step is registered for this file alone.

The confidence provided by the tests is narrow but precise: the first test verifies that diagnostic formatting for component errors uses the correct error code (`ECOMPONENT`), computes line numbers relative to the full source (not just the body slice), and produces a specific formatted string. The second test verifies that the six ordered stages of the pipeline execute in the documented sequence by placing sentinel tokens at positions where each stage would leave a trace, then asserting byte-offset order in the resulting HTML. Neither test exercises error paths through `renderSource` (failed include, failed wiki rewrite, failed asset rewrite, component tokenizer errors, or Apex render failure), nor does either test Textile input.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Shared library module (production + test) |
| Conceptual domain | HTML body rendering pipeline; multi-stage Markdown-to-HTML transform |
| Build or test root | `src/main.zig` (production root); tests run under `zig build test` via the main module's test binary |
| Production runtime dependency | Yes — called by `compile.zig` and any HTML publish path |
| Expected execution command | `zig build test` (exercises embedded tests); product usage via `boris build` |
| Main collaborators | `src/apex.zig`, `src/aside.zig`, `src/parser.zig`, `src/include.zig`, `src/wikilink.zig`, `src/content_asset.zig`, `src/textile.zig`, `src/diag.zig`, `src/graph.zig`, `src/identity.zig` |
| Documentation depth warranted | Medium — the module is brief and its logic is primarily orchestration; depth lies in understanding the ordering contract and lifetime conventions |

***

## Role in the Boris architecture

`html_body.zig` sits between the frontmatter parser and the HTML assembler in the Boris compilation pipeline. It is a pure orchestration layer: it holds no state, allocates only into the caller-supplied `ArenaAllocator` (the "Whiteboard"), and returns a borrowed `[]const u8` slice valid until the arena is reset.

Relative to the product binary (`src/main.zig` → `compile.zig` → `html_body.zig`), the module is a production dependency compiled into every `boris build` invocation whenever an HTML output pass is triggered. It is not gated by any build option or feature flag; `linkApex` applies to the product root, so the Apex C symbols are always present.

Relative to `src/apex.zig`, `html_body.zig` is a consumer. It does not import `apex.zig`'s internal symbols; it calls the public `apex.render(md, doc_arena)` function for each `.markdown` segment. The arena lifetime contract is satisfied because `html_body.zig` holds `doc_arena` alive for the duration of `renderSource` and returns a slice into that same arena.

The hostile C implementation (`vendor/apex/apex_hostile.c`) is irrelevant to `html_body.zig` at runtime. When the `test-apex-hostile` step runs, it compiles a separate test binary rooted at `src/apex_hostile_test.zig` with `hostile_apex = true`; `html_body.zig` is not included in that binary. The module's tests always use the real Apex engine because they are part of the main module test binary, which always links against `vendor/apex/apex.c` and the real static archives.

The module has no direct role in the IR/JSON manifest path, the RAG export path, or the graph resolution step. It operates on a single document at a time after the graph has already been resolved and the caller has provided a `[]const graph_mod.Node` slice for wiki-link rewriting.

***
