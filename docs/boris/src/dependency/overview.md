---
title: "`src/dependency.zig` overview"
id: docs/boris/src/dependency
status: draft
tags: [boris, zig, source-reference, dependency]
---

# `src/dependency.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/dependency/surface-and-execution|Surface and execution]]
* [[docs/boris/src/dependency/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/dependency/review-state|Review state]]

## Executive summary

`src/dependency.zig` is a production library module that defines the typed dependency model for Boris's content graph. It provides three coordinated abstractions: a `DependencyKind` enum that classifies the five recognized edge types in the Boris content graph (`parent`, `layout`, `include`, `reference`, `asset`); a `Dependency` struct that pairs a target path with a kind; and a `DependencyIndex` struct that maintains a bidirectional in-memory index of all dependency edges, serializing them on demand to a deterministic, human-readable JSON representation.

The file exists because Boris's Feature 8 pipeline requires a graph-native intermediate representation. At IR schema version `0.2.0`, the compiler must resolve and emit typed `parent`, `include`, and `reference` edges along with their reverse index, and both the forward and reverse directions must be available to the incremental dirty-set logic introduced in milestone 8.3. `DependencyIndex` is the single structural owner of that bidirectional state. By centralizing deduplication, sorting, and JSON emission in one module, the rest of the pipeline (pipeline.zig, graph.zig, and the IR emitter) can delegate all dependency bookkeeping to a single authoritative data structure.

The file is compiled as an independent Zig module (`dependency_mod` in `build.zig`) with its own test binary and is also imported by production pipeline modules. It has no dependency on the rendering seam. Its tests run as part of `zig build test`. One self-contained integration test is embedded at the bottom of the file, exercising the round-trip from `addDependency` calls through `renderJson`.

The confidence this file provides is focused: it directly demonstrates that the deduplication guard, forward and reverse population, sort stability, JSON structure, and schema version field are all correct for a straightforward multi-node fixture. What it does not prove is behavior under large input volumes, concurrent mutation, or any particular serialization speed guarantee. It also does not test robustness against paths that contain JSON-sensitive characters, nor does it verify that the IR consumer round-trips the JSON back into a `DependencyIndex` correctly.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with embedded unit test |
| Conceptual domain | Content-graph dependency tracking and bidirectional index |
| Build or test root | `src/dependency.zig` (standalone module root in `build.zig`) |
| Production runtime dependency | Yes — imported by pipeline and graph modules |
| Expected execution command | `zig build test` (included in default test step) |
| Main collaborators | `src/json_out.zig` (JSON serialization helpers); `src/pipeline.zig`, `src/graph.zig` (callers, not directly confirmed by reading those files) |
| Documentation depth warranted | Medium — the data model is deliberately simple; the JSON emission logic is more complex and warrants full coverage |

***

## Role in the Boris architecture

`src/dependency.zig` is a leaf-level data module in the production pipeline. It does not import from any file other than `std` and `src/json_out.zig`, so it has no transitive dependencies on the rendering seam, the scanner, the parser, or the graph cycle-detection subsystem. This makes it an unusually clean component: it can be compiled, tested, and reasoned about in isolation.

Relative to the product binary, this module is linked into `boris` via the `root_mod` chain (through pipeline.zig or graph.zig — the exact import chain was not read during this investigation, but is confirmed by build.zig's inclusion of `run_dependency_tests` in the default `test` step and the presence of an independent `dependency_mod`). It is also compiled independently for its own test binary.

Relative to `src/render.zig`, this file has no relationship at all: dependency tracking is a pure Zig data structure with no rendering surface. There is no renderer module link in its build declaration.

Relative to the normal test suite, its test block participates in `zig build test` alongside all other unit tests. It is not a hostile, adversarial, or ABI-focused test; it is a round-trip correctness test for the index itself.

The file is not used by any specialized rendering target.

***
