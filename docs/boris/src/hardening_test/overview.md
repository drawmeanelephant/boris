---
title: "`src/hardening_test.zig` overview"
id: docs/boris/src/hardening_test
status: draft
tags: [boris, zig, source-reference, testing, integration]
---

# `src/hardening_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/hardening_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/hardening_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/hardening_test/review-state|Review state]]

## Executive summary

`src/hardening_test.zig` is the Milestone 10 end-to-end integration and hardening test suite for Boris. It is not a renderer-boundary test file; it exercises the full Zig pipeline — discovery, graph validation, IR emission, RAG export, HTML compilation, component tokenization, and output path enforcement — using the Oliver-backed rendering seam (`src/render.zig`, pinned library). Its purpose is to verify system-level properties that unit tests for individual modules cannot demonstrate: that repeated independent runs of the same pipeline over identical content produce byte-for-byte identical outputs (`manifest.json` and `graph.json`), that the IR pipeline and the RAG pipeline agree on graph diagnostic codes for every category of structural error, that file-system enumeration order cannot influence the sorted document ordering or the emitted JSON, that duplicate content IDs are reported rather than silently collapsed, that output path derivation refuses traversal and absolute inputs, and that component validation is enforced on both the IR and HTML compile paths.

The file exists because Boris's correctness guarantee is not only "each module is correct in isolation" but also "the composed pipeline is stable, reproducible, and safe to run repeatedly." Without these tests a regression could cause the build report to embed a non-deterministic value, the scanner to order pages differently on different file systems, the graph module to silently drop one of two colliding IDs, or the identity module to allow a path containing `..` to escape the configured output root. These properties are structurally difficult to verify in a single-module test because they span allocation arenas, file I/O, JSON serialization order, and the interaction between graph validation and downstream emitters.

The file is executed as part of `zig build test` — it is not opt-in. It is also reachable in isolation via `zig build test-harness`. It renders through the pinned Oliver dependency via `render_mod`; no C libraries are linked. Temporary artifacts are written under `test-output/` (gitignored) in randomly suffixed directories created per test, cleaned up by `WorkDir.cleanup()` on `defer`.

The confidence provided is high for the properties that are directly demonstrated by byte-identical comparison of actual emitted files. It is weaker for properties that depend on the internal behavior of `pipeline.run` or `rag.run` not being inspected further — for example, the determinism tests prove that two sequential runs on the same host produce identical output, but do not prove that output is identical across platforms with different `readdir` ordering, different file-system timestamps, or different endianness. The file does not test concurrency, file watching, mmap, or incremental cache invalidation (those are covered by separate modules); and it does not test the rendering seam's error mapping in isolation (that is `src/render.zig`'s own tests).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Integration test (end-to-end hardening) |
| Conceptual domain | Pipeline determinism, graph diagnostics, output path safety, component validation, HTML rendering |
| Build or test root | `src/hardening_test.zig` (standalone root module `hardening_mod` in `build.zig`) |
| Production runtime dependency | None — compiled only for tests, never linked into the `boris` binary |
| Expected execution command | `zig build test` (included) or `zig build test-harness` (alias step) |
| Main collaborators | `pipeline.zig`, `rag.zig`, `graph.zig`, `compile.zig`, `identity.zig`, `aside.zig`, `diag.zig`, `page.zig`, `scanner.zig` |
| Documentation depth warranted | Medium-high: cross-cutting integration contracts; each test group deserves its own entry in a contract reference |

## Role in the Boris architecture

`hardening_test.zig` sits above all individual subsystem modules in the dependency graph and calls into them through their public APIs exactly as a CLI invocation would. It is the only test file (other than `src/incremental_scale_smoke_test.zig`, which is opt-in) that drives the full pipeline from raw Markdown content on disk to emitted JSON or HTML artifacts and then reads those artifacts back to verify their content. It does not import `src/render.zig` directly; Oliver is reached transitively through `pipeline.zig`, `rag.zig`, `compile.zig`, and `aside.zig`, each of which renders through the `render_mod` seam.

The file is distinct from the normal per-module test suites (`pipeline.zig` has its own `test` blocks, as do `graph.zig`, `aside.zig`, `rag.zig`, etc.). Those suites test narrow functional correctness; `hardening_test.zig` tests cross-cutting properties — determinism, diagnostic convergence, path containment — that only become observable when multiple subsystems are composed. It is also distinct from `src/render.zig`'s own unit tests, which validate the Oliver-backed seam's output contracts in isolation.

`hardening_test.zig` is not linked into the product binary. Its imports (`pipeline`, `rag`, `graph_mod`, `compile`, `identity`, `scanner`, `page_mod`, `aside`, `diag`) are all resolved at compile time from the Zig module graph; no runtime dispatch or dynamic linking is involved.
