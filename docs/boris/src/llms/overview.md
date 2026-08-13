---
title: "`src/llms.zig` overview"
id: docs/boris/src/llms
status: draft
tags: [boris, zig, source-reference, llms]
---

# `src/llms.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/llms/surface-and-execution|Surface and execution]]
* [[docs/boris/src/llms/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/llms/review-state|Review state]]

## Executive summary

`src/llms.zig` is the production implementation of Boris's `llms.txt` community-standard export. It is a self-contained module that, given a validated Boris content graph, produces a single human- and machine-readable plain-text file in the format prescribed by the emerging `llms.txt` convention: a Markdown-structured index of site pages, each rendered as a link-plus-summary bullet point.

The file exists because `llms.txt` has become a community mechanism for exposing structured documentation summaries to large-language-model consumers. Boris's graph already encodes the parent/child document hierarchy and frontmatter metadata needed to render a useful `llms.txt`, so the exporter is a thin, pure-Zig projection of that graph rather than a separate parsing or rendering subsystem. The module comment is explicit: it "deliberately does not invent a second parser or URL/frontmatter dialect."

The module boundary it owns is: validated graph → deterministic flat-text file. It delegates all content discovery, frontmatter parsing, and graph resolution to `pipeline.zig` (via `pipeline.compile`). Once compilation succeeds it reads source files directly to extract prose summaries, renders the page tree recursively, and writes the result via a staged atomic-ish rename sequence to `opts.out_path`.

Execution happens entirely on the calling thread. There is no concurrency, no background I/O, and no C ABI involvement. The `run` function is the sole public entry point. It is called from `src/main.zig` (and, by extension, the `boris` CLI) when the user invokes the `llms` command or equivalent. Build configuration (`build.zig`) does not define a standalone module or test step for `llms.zig`; its one inline test is exercised via the `root_mod`/`unit_tests` step that roots at `src/main.zig` and transitively includes all modules reachable from it.

The file provides moderate confidence that the core `summary` extraction logic is correct for the two cases it tests (frontmatter-stripped first paragraph, and heading-only/empty fallback to title). It does not provide end-to-end integration test coverage: the atomic publish sequence, the recursive tree render, the URL construction, the `appendInline` escaping, and the `findChildren`/`renderPage` recursion are not independently tested in this file.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module |
| Conceptual domain | Content export / LLM-consumption surface |
| Build or test root | Reachable from `src/main.zig` via `@import("llms.zig")`; compiled as part of `unit_tests` |
| Production runtime dependency | Yes — called by `src/main.zig` when `llms` subcommand is invoked |
| Expected execution command | `zig build test` (unit test inline); `zig build run -- llms` (production) |
| Main collaborators | `src/pipeline.zig`, `src/graph.zig`, `src/identity.zig`, `std.Io` |
| Documentation depth warranted | Medium — module is small but owns the atomic publish sequence and inline-escaping contract |

***

## Role in the Boris architecture

`src/llms.zig` sits at the end of Boris's main pipeline. It is linked unconditionally into the product binary: `build.zig` roots the product executable and unit-test binary at `src/main.zig`, and `llms.zig` is reached transitively through that import chain. It is not compiled into any separate test step, and it has no dependency on the Markdown renderer.

In the pipeline sequence it occupies the final "emit to disk" position:

```text
src/main.zig
    → llms.run(io, gpa, opts)
        → pipeline.compile(io, gpa, ...)    [discovery + validation]
        → readFileAlloc × N                 [raw source for summary extraction]
        → render(gpa, result, sources)      [tree render into []u8]
        → publish(io, gpa, path, data)      [staged atomic write]
```

It has no relationship to `src/render.zig` or the Oliver-backed rendering seam. It does not render Markdown to HTML; it produces plain text output formatted with `llms.txt` conventions. The `src/rag.zig` module occupies a parallel role for machine-consumption export (RAG corpus), but the two modules are independent.

***
