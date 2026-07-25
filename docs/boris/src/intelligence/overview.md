---
title: "`src/intelligence.zig` overview"
id: docs/boris/src/intelligence
status: draft
tags: [boris, zig, source-reference, intelligence]
---

# `src/intelligence.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/intelligence/surface-and-execution|Surface and execution]]
* [[docs/boris/src/intelligence/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/intelligence/review-state|Review state]]

## Executive summary

`src/intelligence.zig` is the pure graph-analysis core for Boris's Documentation Intelligence subsystem. It accepts a frozen snapshot of the page and edge graph — already resolved by the upstream pipeline — and returns a structured report describing reachability, unreferenced content, fan-in hotspots, and transitive impact sets. It deliberately carries no filesystem access, no CLI flags, no HTML rendering, no IR serialization, no RAG policy, and no dependency on `src/apex.zig` or any external C library. The module's module-level documentation comment makes this boundary contract explicit.

The file exists because the Boris pipeline produces a rich directed graph of content relationships (parent/child, reference, include, and other typed edges), and the product needs an analysis layer that can answer structural questions about that graph without coupling to any particular output surface. Documentation Intelligence was originally shipped as part of v0.4.0 and has been stable on `main` since PRs #43 and #44. It is included in the default `zig build test` suite via its own named module (`intelligence_mod` / `run_intelligence_tests`), which `build.zig` creates directly from this file as a root source with no extra imports, no Apex link, and no build options. 

The boundary this file protects is the separation between **graph analysis** and every output adapter (HTML, IR, RAG, CLI). By receiving caller-owned slices of `Page` and `Edge` structs and returning a caller-`deinit`-able `Report`, it can be tested in complete isolation and invoked from any caller that has already frozen its pipeline graph — without risk of I/O side effects or premature entanglement with rendering state. The result `Report` owns only its two `ArrayListUnmanaged` fields (`findings` and `impact`); the endpoint string slices inside those fields are borrowed from the caller's page and edge data and remain caller-owned. This lifetime dependency is documented in the `analyze` function's doc comment but is **not mechanically enforced** by the type system: if a caller releases its page/edge slices before rendering the report, the behavior is undefined.

The three inline tests — covering parent-vs-reference edge discrimination, multi-hop impact traversal and deterministic sort order, and fan-in hotspot detection — run under `std.testing.allocator`, which detects leaks. They directly demonstrate the three main behavioral invariants: (1) parent-typed edges do not count as incoming references for unreferenced-page detection; (2) `collectImpact` walks the reverse-edge graph breadth-first and emits a deterministically sorted list excluding the root itself; (3) a `fan_in_threshold` applied to source endpoints correctly counts distinct targets, aggregates incoming-edge counts, and records findings. What the tests do not cover includes: empty input slices, duplicate page IDs, edges referencing pages not in the pages slice, extremely large inputs, the `Options.fan_in_threshold == 0` short-circuit path (implicitly covered by the hotspot test which uses threshold 2, but the zero-threshold bypass is not tested with explicit assertion that no hotspot findings are emitted), and mixed-type endpoint sorting edge cases.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with self-contained unit tests |
| Conceptual domain | Graph analysis / Documentation Intelligence |
| Build or test root | `src/intelligence.zig` is both; it is the root source file for its own test module (`intelligence_mod`) and is imported by callers in the broader pipeline |
| Production runtime dependency | Yes — analysis logic is intended to be callable from the product CLI or pipeline; however, no call site in `src/main.zig` or `src/pipeline.zig` is confirmed in the evidence inspected here; CLI wiring is described as a "separate product slice" in the build comment |
| Expected execution command | `zig build test` (included in the default test step) |
| Main collaborators | `std.mem.Allocator` (allocation); callers that freeze and hand in `Page`/`Edge` slices; `src/pipeline.zig` or equivalent graph-freezing layer (call site uncertain) |
| Documentation depth warranted | Medium — the module is small, pure, and well-scoped; its boundary contract and lifetime semantics are the primary documentation surface |

## Role in the Boris architecture

`src/intelligence.zig` is a **leaf module** in the Boris dependency graph. It imports only `std` and defines all its types locally. It does not import `src/apex.zig`, `src/graph.zig`, `src/pipeline.zig`, or any other Boris module, and `build.zig` confirms this: the `intelligence_mod` is created with only `root_source_file` and no `imports` array, and `linkApex` is not called for it.  This makes it entirely independent of the C ABI surface and safe to compile and test on any host without the ApexMarkdown static libraries.

Within the broader pipeline, `src/intelligence.zig` is intended to operate **after** the pipeline has resolved the graph and frozen it: the `analyze` function's comment says "Analyze a frozen page/edge snapshot." The pipeline stages described in `docs/STATUS.md` are Load → Roll → Ignite → Reset; Documentation Intelligence analysis logically sits between the Roll/graph-resolution phase and the Ignite/output phase, consuming the frozen graph as read-only input. 

The module is **not** linked into the production binary in any direct sense visible from `build.zig` — there is no `addImport("intelligence", intelligence_mod)` call attaching it to `root_mod`. The build comment for the intelligence section reads: "Pure graph analysis; CLI wiring remains a separate product slice."  This means the module exists and is tested, but its integration into the product CLI is **uncertain from the inspected build configuration alone**; it may be imported transitively by another module not surfaced in `build.zig` at the module-creation level, or the CLI wiring may be genuinely pending.

The hostile Apex test infrastructure (`apex_hostile_lib_mod`, `apex_hostile_root`) is entirely separate and uses `vendor/apex/apex_hostile.c` as a replacement C symbol source. `src/intelligence.zig` has no interaction with that subsystem.
