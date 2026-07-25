---
title: "`src/pipeline.zig` overview"
id: docs/boris/src/pipeline
status: draft
tags: [boris, zig, source-reference, pipeline, compiler]
---

# `src/pipeline.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/pipeline/surface-and-execution|Surface and execution]]
* [[docs/boris/src/pipeline/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/pipeline/review-state|Review state]]

## Executive summary

`src/pipeline.zig` is the central orchestration module for the Boris content-compiler. It owns the complete lifecycle of a build: filesystem scan → per-file read → frontmatter parsing → component tokenization → PageDb promotion → graph validation → semantic-relation validation → dependency resolution → dependency-index freeze → JSON artifact publication. It is the single entry point through which both the IR export path (`run`) and the shared compile-only path (`compile`) pass, ensuring that both modes apply identical graph-validation and diagnostic semantics.

The file has no dependency on ApexMarkdown for its primary IR pipeline path. Its module-level comment explicitly states "No HTML, layouts, or Apex on this path." ApexMarkdown enters only through transitive compilation of `aside.zig`, which is imported via `aside.tokenizeBody`. Because `aside.zig` is linked with Apex, `pipeline.zig` must also be linked with the real (or hostile) Apex adapter at build time, but `pipeline.zig` itself never calls any Apex symbol directly. This distinction is structurally important: Apex link is a build dependency, not a behavioral one, for the IR pipeline.

The file defines several key public types — `Options`, `CompileOptions`, `Result`, `FailureKind`, `Endpoint`, `DependencyEdge`, `ReverseEntry`, `EndpointType` — that form the stable external contract for callers (`src/main.zig`, `src/rag.zig`, `src/package.zig`). The `Result` struct is a caller-owned value that holds an arena, two GPA-backed lists (pages, edges, reverse index), a diagnostics list, and state flags (`ok`, `graph_frozen`, `published_graph_ir`, `failure`). Its `deinit` method mixes arena and GPA deallocation: GPA lists are freed individually first, then the arena is torn down, so the arena must never be used to allocate the list headers themselves — a requirement enforced by inspecting the `deinit` body.

Three public JSON-rendering functions (`renderManifest`, `renderGraph`, `renderBuildReport`) delegate entirely to `src/ir_emit.zig`, passing a version-constant bundle. Version constants are declared at the top of the file: `schema_version = "0.2.0"`, `compiler_id = "boris/0.8.0"`, `semantic_schema_version = "0.3.0"`, `semantic_compiler_id = "boris/0.8.0+semantic-relations"`, and `boris_version = "0.8.0"`. These are the authoritative source of version identity embedded in every build output.

The embedded test suite is large and integration-level. Tests run against real fixture trees under `docs/contracts/fixtures/` and `fixtures/content/`, covering: successful three-artifact build and JSON shape validation, Textile mode acceptance and rejection, graph-native dependency fixture golden comparison, include/wiki failure gating, wiki fragment edge semantics, duplicate-ID stale-IR cleanup, stable diagnostic codes across all invalid-graph fixture categories, two-run byte-identical determinism, render-twice no-entropy check, fixture ordering, metadata lifetime across source-buffer free, frontmatter error mapping, missing-content-root EIO handling, and per-file read-permission failure on POSIX hosts.

The file does not test anything related to the Apex C ABI, HTML rendering, RAG export, or incremental/HMR paths. Those concerns belong to `src/apex.zig`, `src/apex_hostile_test.zig`, `src/rag.zig`, and related modules.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production pipeline module with embedded integration tests |
| Conceptual domain | Content compiler orchestration: scan → validate → emit IR |
| Build or test root | `src/pipeline.zig` (test root for `pipeline_tests` build target) |
| Production runtime dependency | Yes — imported transitively by `src/main.zig`, `src/rag.zig`, and `src/package.zig` |
| Expected execution command | `zig build test` (via `run_pipeline_tests`); `zig build test-pipeline` not a named step — included in global `test` step |
| Main collaborators | `src/scanner.zig`, `src/parser.zig`, `src/aside.zig`, `src/graph.zig`, `src/ir_emit.zig`, `src/page.zig`, `src/include.zig`, `src/wikilink.zig`, `src/dependency.zig`, `src/identity.zig`, `src/textile.zig`, `src/diag.zig` |
| Documentation depth warranted | High — this is the primary public API surface for all build-pipeline callers |

## Role in the Boris architecture

`src/pipeline.zig` sits one layer above all individual subsystem modules and one layer below the CLI entry point (`src/main.zig`) and the RAG/package tools. It is linked into the product binary: `build.zig` creates `pipeline_mod` from `src/pipeline.zig`, calls `linkApex(pipeline_mod, b, false)` (real ApexMarkdown adapter, not hostile), and adds it to the `test` step via `run_pipeline_tests`. The same `pipeline_mod` import chain feeds `root_mod` (the product CLI).

The pipeline module does **not** use ApexMarkdown at runtime. The Apex link is required only because `src/aside.zig` is `@import`-ed, and `aside.zig` in turn calls `@cImport` on the Apex host ABI header. Removing the `linkApex` call from `pipeline_mod` would produce a linker error even though no Apex symbol is reachable from `pipeline.zig`'s own code paths in the IR build mode.

`src/apex_hostile_test.zig` is a completely separate build target (`apex_hostile_root`) that imports `src/apex.zig` directly — not `src/pipeline.zig`. There is no code path through which `pipeline.zig` reaches the hostile C double. The hostile double is compiled only when the `test-apex-hostile` step is explicitly invoked.

The compile path (`compile`) is shared by both `run` (IR pipeline, writes to disk) and `src/rag.zig`'s `rag.run` (RAG export). This sharing is structurally enforced by the module-level comment and by the fact that `rag.zig` is a separate module that calls `pipeline.compile` rather than re-implementing scan/parse/graph-validate. The design intent is a single graph-validation entry point with diagnostic category parity across both output modes.
