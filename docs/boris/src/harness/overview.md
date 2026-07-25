---
title: "`src/harness.zig` overview"
id: docs/boris/src/harness
status: draft
tags: [boris, zig, source-reference, harness]
---

# `src/harness.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/harness/surface-and-execution|Surface and execution]]
* [[docs/boris/src/harness/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/harness/review-state|Review state]]

## Executive summary

`src/harness.zig` is a shared test infrastructure module for Boris. It provides the `WorkDir` type, shared file-system helpers, and a collection of integration tests that exercise the full content-compilation pipeline end-to-end. The file is not compiled into the production binary and is not referenced by `zig build test`. Its module-level doc comment explicitly marks it as **superseded** by `src/hardening_test.zig` and the per-module test suites (`aside`, `pipeline`, `rag`, `compile`, `fuzz`); it is retained in the repository as a reference for older API experiments.

Despite being off the default build graph, the file is substantive rather than vestigial. It contains a full suite of named integration tests covering: valid multi-page trunk/satellite IR builds, invalid graph diagnostics (duplicate IDs, missing parents, self-parent, cycles, satellite-of-satellite), frontmatter syntax and UTF-8 encoding failures, component tokenizer failures and valid rendering, empty and large-but-bounded Apex invocations, layout marker errors, RAG vs IR path separation, reproducibility across two independent runs, whiteboard reset isolation across pages, static committed fixture coverage, discovery sort independence, compile fast-fail on bad layout, static layout fixtures, UTF-8 BOM fixture rejection, and component-fail fixture diagnostics. These tests exercise the pipeline, scanner, parser, frontmatter, apex, aside, assemble, compile, rag, and page modules together, making the file a broad end-to-end integration snapshot.

The system boundary protected by this file is the full Boris compilation pipeline as visible from outside any individual subsystem: content discovery through graph resolution, HTML rendering, artifact emission, and output determinism. It does not protect the Apex C-ABI boundary specifically — that role belongs to `src/apex_hostile_test.zig` and the inline `mapRenderResult` tests in `src/apex.zig`.

The file is **not** on the build graph of `zig build test`, `zig build test-harness`, or any other currently declared build step. The module-level doc comment acknowledges this explicitly and directs readers to the active coverage targets. No build step was found in `build.zig` that compiles or runs `src/harness.zig`. Therefore, all tests within the file are **not currently executed** unless a developer adds a custom step or runs the file directly. The confidence provided by this file is accordingly **historical and documentary**: it captures integration intent and fixture contracts as they existed before the test suite was reorganised, but provides no active CI assurance.

What the file does not prove: it does not prove the tests pass against the current codebase. It does not prove the API signatures it imports still match their current forms (`Io.Dir.cwd()`, `pipeline.run`, `rag.exportAll`, etc.). It does not prove any Apex ABI property. It is not a hostile ABI test.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Integration test module (historical/superseded; off build graph) |
| Conceptual domain | Full pipeline: content discovery → graph resolution → IR/HTML/RAG emission |
| Build or test root | None — not compiled by any declared `build.zig` step |
| Production runtime dependency | No |
| Expected execution command | None currently; historically intended as integration harness |
| Main collaborators | `pipeline`, `scanner`, `parser`, `frontmatter`, `apex`, `aside`, `assemble`, `compile`, `rag`, `page`, `graph`, `diag` |
| Documentation depth warranted | Medium — rich test intent; zero current CI value |

***

## Role in the Boris architecture

`src/harness.zig` sits entirely outside the product binary and outside the active test graph. It is not linked into any executable. Its role is historical: before the test suite was split into per-module tests and the dedicated hardening integration file (`src/hardening_test.zig`), this file served as the single integration harness for the compiled pipeline.

Relative to `src/apex.zig`, the harness uses the public `apex.render` function normally — as a real content-rendering call during its whiteboard and rendering tests — but does not attempt to exercise the C ABI directly. It imports `apex` as a module peer, not as a tested boundary. The hostile C implementation (`vendor/apex/apex_hostile.c`) is irrelevant to this file: `src/harness.zig` is never linked against it.

Relative to the normal test suite declared in `build.zig`, this file is a displaced predecessor. The active `test` step includes `hardening_test.zig`, per-module tests for `pipeline`, `aside`, `rag`, `compile`, and `fuzz`, but does not include `harness.zig`. The `test-harness` build step (declared in `build.zig`) is an alias for `hardening_test.zig`, not for this file, despite the name overlap.

***
