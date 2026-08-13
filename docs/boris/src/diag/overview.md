---
title: "`src/diag.zig` overview"
id: docs/boris/src/diag
status: draft
tags: [boris, zig, source-reference, diag]
---

# `src/diag.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/diag/surface-and-execution|Surface and execution]]
* [[docs/boris/src/diag/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/diag/review-state|Review state]]

## Executive summary

`src/diag.zig` is the canonical diagnostic data model for the Boris content compiler. It defines every structured type needed to represent, sort, format, and count compiler diagnostics: the `Severity` enum, the closed `Code` enum, the `Diagnostic` struct, a deterministic sort comparator and wrapper, a text formatter for stderr output, and an error counter. The file's module-level doc comment states explicitly that code strings match `docs/contracts/diagnostics.md` exactly and that diagnostic string fields are owned by the caller's retain allocator.

The file exists because Boris must emit machine-readable, stable-category diagnostics to both stderr (text) and `build-report.json` (JSON), and because the normative contract in `docs/contracts/diagnostics.md` requires those codes, field names, and sort order to be frozen for fixture testing, CI, and downstream tooling. By centralizing the type definitions and enforcing them through `@tagName` (which derives the code string directly from the enum variant name), the compiler gains a single authoritative source of truth that is structurally incapable of emitting an alias or underscore variant without a source change.

`src/diag.zig` is a shared import, not a standalone module root. It has no build entry of its own in `build.zig`; its embedded tests execute when any of the modules that import it are compiled under `zig build test`. The module has no external dependencies beyond `std` — no renderer link, no `build_options`, no platform-specific code.

The confidence provided is twofold. The `"Code names match contract strings"` test directly demonstrates that 17 of the 21 declared codes produce the exact string expected by the normative contract, using `@tagName` as the mechanism. The `"sortDiagnostics orders by path then line"` test directly demonstrates that the primary (path) and secondary (line) sort keys work correctly for a three-element fixture. What the tests do not prove includes: the four codes omitted from the name test (`ERELATIONMISSING`, `ERELATIONSELF`, `ERELATIONDUPLICATE`, `EASSET`); the behavior of the tertiary (column), quaternary (code), and quinary (message) sort keys; the correctness of `formatText` for all three text-form branches; or behavior of `countErrors` beyond what callers exercise.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production shared library module with embedded unit tests |
| Conceptual domain | Structured compiler diagnostics — types, codes, sort, format, count |
| Build or test root | None standalone; compiled transitively via `src/pipeline.zig`, `src/graph.zig`, `src/parser.zig`, and others |
| Production runtime dependency | Yes — imported throughout the production pipeline |
| Expected execution command | `zig build test` (tests run as part of importing module roots) |
| Main collaborators | `src/pipeline.zig` (aggregation + stderr), `src/graph.zig` (graph codes), `src/parser.zig` (parse categories), `src/json_out.zig` (JSON serialization, in callers) |
| Documentation depth warranted | Medium-high — the Code enum and its contract alignment warrant thorough coverage; the helper functions are simple but have correctness-critical edge cases |


***

## Role in the Boris architecture

`src/diag.zig` sits at the base of the diagnostics subsystem. It has no imports from other Boris modules — only `std` — so it is a true leaf in the import graph. Every module that needs to create, sort, or format a diagnostic imports this file. This makes it a shared vocabulary layer rather than a subsystem with behavior of its own.

Relative to the product binary, `diag.zig` is compiled into `boris` via every module that imports it. It is not linked directly as a named module in `build.zig`; instead it participates in the transitive closure of `root_mod` (through pipeline.zig), `pipeline_mod`, `graph_mod`, `parser_mod`, and similar roots. Its tests therefore run inside those modules' test binaries rather than in a dedicated artifact.

Relative to `src/render.zig`, `diag.zig` has no relationship. Diagnostics are a pure Zig concern; the rendering seam may surface an error after `render.render` returns, but mapping it onto a diagnostic is a caller concern, not this file's.

Relative to `docs/contracts/diagnostics.md`, `diag.zig` is the normative implementation counterpart. The contract document specifies the closed code set, JSON field names, sort order, and text format; `diag.zig` implements all of these directly.

***
