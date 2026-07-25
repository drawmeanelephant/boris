---
title: "`src/graph.zig` overview"
id: docs/boris/src/graph
status: draft
tags: [boris, zig, source-reference, graph, validation]
---

# `src/graph.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/graph/surface-and-execution|Surface and execution]]
* [[docs/boris/src/graph/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/graph/review-state|Review state]]

## Executive summary

`src/graph.zig` is the central graph-validation and navigation-construction module for the Boris content compiler. It defines the in-memory representations of content-graph nodes, edges, and navigation structures, and provides all operations that transform a flat list of parsed, metadata-carrying nodes into a validated, frozen, and navigable directed acyclic graph (forest).

The file exists because Boris's architecture separates content discovery and metadata parsing from structural validation. After `pipeline.zig` (and `rag.zig`) parse frontmatter into a flat `[]Node` array, they delegate all structural correctness work to this module before emitting any output. The module is therefore a hard gate: no graph-dependent JSON output (`graph.json`, `manifest.json`, RAG graph files) may be produced until `validate` returns cleanly and `freeze` completes.

The system boundary protected is the parent-child relationship graph. Violations the module enforces include: duplicate entity IDs (exact-match and case-only collision), self-referential parents, missing parents, satellite-of-satellite multi-hop chains (forbidden in v0.1), and directed cycles among parent links. Each violation produces a structured `diag.Diagnostic` with a normative error code matched to `docs/contracts/diagnostics.md`. The module does not abort early; it collects all diagnostics so callers can report every error in a single pass.

Execution is via `zig build test` or `zig test src/graph.zig` (with its transitive imports). The module's tests are declared inline using Zig's `test` blocks and are compiled and run as part of the standard library test step. There is no separate test binary for this file.

The confidence provided is good for the tested structural cases: missing parents, self-parents, two-node cycles, three-node cycles, satellite-of-satellite chains, duplicate IDs (exact and case-variant), freeze index remapping, layout-edge emission, and full navigation derivation with breadcrumbs, children, and siblings. The module does not prove correctness under concurrent mutation, does not test large-scale cycle topologies, and does not test error-path cleanup when individual `diags.append` allocations fail mid-validation.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Core library module with inline unit tests |
| Conceptual domain | Content graph — validation, topology, freeze, navigation |
| Build or test root | Compiled into the main Boris binary and test steps; not a standalone binary |
| Production runtime dependency | Yes — `pipeline.zig` and `rag.zig` call `validate`, `freeze`, and `buildNav` |
| Expected execution command | `zig build test` or `zig test src/graph.zig` (with dependency modules) |
| Main collaborators | `src/diag.zig` (diagnostic types and codes), `src/identity.zig` (`pathsDifferOnlyInCase`), `src/page.zig` (`SemanticRelation`) |
| Documentation depth warranted | High — this is the normative validation entry point for all graph-dependent output |

***

## Role in the Boris architecture

`src/graph.zig` sits between the parse/metadata layer and the IR-emit layer. After frontmatter is extracted from content files and assembled into a `[]Node` slice, this module performs all structural validation and freezes the result into the canonical `Graph` value that emitters consume.

The module is linked directly into the production binary. It is not a test-only file. The `validate` function is explicitly documented as the **single shared graph-validation entry point** for both `pipeline.zig` and `rag.zig`, with a normative doc comment forbidding reimplementation of parent resolution, duplicate-ID checks, or cycle detection in those modules.

`src/apex.zig` and the ApexMarkdown C ABI are unrelated to this module. `src/graph.zig` operates purely on Zig-owned data structures and performs no I/O and no C interop.

The `resolve` public declaration is an alias for `validateTopology` maintained for historical call sites; it does not represent a distinct code path.

`buildNav` and `freeNav` are used post-freeze to produce per-page navigation data (breadcrumbs, child lists, sibling lists) for the render layer.

***
