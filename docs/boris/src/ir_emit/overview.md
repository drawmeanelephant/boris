---
title: "`src/ir_emit.zig` overview"
id: docs/boris/src/ir_emit
status: draft
tags: [boris, zig, source-reference, ir_emit]
---

# `src/ir_emit.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/ir_emit/surface-and-execution|Surface and execution]]
* [[docs/boris/src/ir_emit/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/ir_emit/review-state|Review state]]

## Executive summary

`src/ir_emit.zig` is the **deterministic JSON serialization layer** for Boris's IR artifacts: `manifest.json`, `graph.json`, `completion.json`, and `build-report.json`. It contains four public entry-point functions — `renderManifest`, `renderGraph`, `renderCompletion`, and `renderBuildReport` — each of which accepts a caller-owned, already-validated pipeline result and a `VersionInfo` struct, and returns a freshly heap-allocated `[]u8` containing a complete, pretty-printed JSON document. The file's module-level comment states its intent precisely: "Pure, deterministic JSON artifact renderers for frozen Boris IR data. This module borrows its input and intentionally does not import pipeline."

The module exists to separate the concerns of pipeline orchestration (owned by `src/pipeline.zig`) from artifact serialization. `pipeline.zig` calls each renderer through thin wrappers that supply the version constants, then publishes the returned bytes; `ir_emit.zig` never touches the filesystem, never allocates on the pipeline's arena, and never calls any external API. All three renderers follow the same structural pattern: open a `std.ArrayList(u8)` with an `errdefer buf.deinit`, build JSON incrementally using helpers from `src/jsonout.zig`, and return `buf.toOwnedSlice()` to the caller.

The schema version branching logic is a notable design decision: if any page in the result carries semantic relations (`page.semantic_relations.len > 0`), all three artifacts use `versions.semantic_schema_version` and `versions.semantic_compiler_id` (currently `"0.3.0"` and `"boris/0.8.1+semantic-relations"`); otherwise they use the base `"0.2.0"` / `"boris/0.8.1"` constants. This branching is computed through the private helpers `hasSemanticRelations`, `artifactSchemaVersion`, and `artifactCompilerId`, which inspect the live result, not a cached flag.

`renderGraph` alone performs a non-trivial allocation: it calls `graph.buildNav` to derive the navigation sidebar data (`breadcrumb`, `children`, `siblings` arrays keyed by frozen node index), then serializes that structure as a `nav` top-level array in `graph.json`. The nav is owned by `ir_emit.zig` for the duration of the render and freed with `graphmod.freeNav` under `defer` before the function returns. The `relations` array in `graph.json` is only emitted when `hasSemanticRelations` is true; the field is omitted entirely in the base-IR case.

The module has **no tests of its own**. Coverage comes from two external sources: `src/ir_schema_conformance_test.zig`, which runs the renderers through `pipeline.run` on a real fixture and validates the output against the published JSON Schema files under `docs/contracts/schemas/`; and `src/hardening_test.zig`, which asserts byte-identical outputs for dual-run determinism on `manifest.json` and `graph.json`. The schema conformance test is the closest thing to a specification enforcement gate for this module; it verifies both that required properties are present and that no undocumented properties have been added.

What this module does **not** prove: it does not guarantee that the JSON is valid according to any external parser's interpretation — only that the bytes it produces conform to the specific subset of JSON Schema validated by the in-repo validator. It does not sort or re-order the caller's `pages.items`, `edges.items`, or `reverse_index.items` slices; determinism is assumed from the pipeline's freeze phase. It does not escape control characters in the 0x00–0x1F range beyond the six standard JSON escape sequences handled by `jsonout.escapeAppend`; robustness against embedded NUL bytes in content strings is not demonstrated by any test.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module (pure serialization) |
| Conceptual domain | IR artifact emission; deterministic JSON serialization |
| Build or test root | Imported by `src/pipeline.zig`; compiled into the product binary and all test steps that import `pipeline` |
| Production runtime dependency | Yes — `pipeline.renderManifest`, `pipeline.renderGraph`, `pipeline.renderCompletion`, `pipeline.renderBuildReport` are thin wrappers over this file |
| Expected execution command | Exercised indirectly by `zig build test`, `zig build test-harness`, `zig build package`; schema conformance specifically via `zig build test` (includes `src/ir_schema_conformance_test.zig`) |
| Main collaborators | `src/graph.zig` (`buildNav`, `freeNav`), `src/jsonout.zig` (all primitive writers), `src/pipeline.zig` (caller, version constants, `Result` type) |
| Documentation depth warranted | Medium-high — this is the canonical serialization layer for the published IR contract |

***

## Role in the Boris architecture

`src/ir_emit.zig` sits at the **boundary between pipeline computation and artifact publication**. The pipeline (`src/pipeline.zig`) owns discovery, parsing, graph validation, dependency resolution, and the `Result` struct; `ir_emit.zig` consumes a frozen, caller-owned `Result` and produces serialized bytes that `pipeline.publishArtifacts` then writes to disk.

The four public functions are called from `pipeline.renderManifest`, `pipeline.renderGraph`, `pipeline.renderCompletion`, and `pipeline.renderBuildReport` (lines near the `--- JSON renderers ---` banner in `pipeline.zig`). Those wrappers supply version constants derived from the `pipeline` module's own `pub const` declarations (`schemaVersion`, `compilerId`, `semanticSchemaVersion`, `semanticCompilerId`). No other caller in the current codebase invokes `ir_emit` functions directly; the public API boundary is the pipeline wrappers.

The module is **linked into the production binary** via `pipeline.zig`. It is not guarded by any build option or feature flag. The `context.zig` module calls `pipeline.renderGraph` (and therefore `ir_emit.renderGraph`) for its context bundle export, so `ir_emit.zig` is also on the `boris --context` path.

`ir_emit.zig` intentionally does **not** import `pipeline.zig`. This import inversion is load-bearing: it prevents circular dependencies and keeps the serializer testable with any struct that satisfies the duck-typed interface used by the `anytype` parameters.

***
