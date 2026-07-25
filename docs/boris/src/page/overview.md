---
title: "`src/page.zig` overview"
id: docs/boris/src/page
status: draft
tags: [boris, zig, source-reference, page]
---

# `src/page.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/page/surface-and-execution|Surface and execution]]
* [[docs/boris/src/page/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/page/review-state|Review state]]

## Executive summary

`src/page.zig` is the canonical type and data hub for Boris's content model across milestones 4 through 6. It defines every shared data structure that a content item passes through — from first discovery by the scanner, through frontmatter parsing, to durable storage in the compile session's `PageDb`. No I/O, no rendering, no graph resolution: the file is purely a type-level and ownership contract implemented as a Zig library module.

The file exists because Boris separates content identity (stable during the entire compile session) from transient parser views (valid only for the lifetime of a source buffer). Without a single authoritative module for this distinction, each pipeline stage would reinvent the boundary, creating aliasing bugs and lifetime violations. `src/page.zig` draws that line exactly once: `FrontmatterView` holds slices into a caller-owned source buffer; `DurablePage` holds retain-arena-owned copies; `PageDb.promote` performs the explicit crossing.

The system boundary the file protects is allocator ownership. Every string field on `Page`, `DurablePage`, and `PageDb` is documented as retain-arena-owned. Parser source buffers — which may be freed at any time after parsing — must never be stored on a `DurablePage` without going through `PageDb.promote` or explicit `PageDb.dupe`/`dupeOpt` calls. The module enforces the contract structurally (via separate types) but cannot prevent a caller from constructing a `DurablePage` manually with a wrong-lifetime slice; that gap is a documented caller obligation.

The file is compiled into every test target and the product binary that imports the pipeline. It has no runtime dependency on the Apex C ABI, on I/O, or on any external library. Its own `test` blocks exercise sorting, status parsing, and the `PageDb.promote` ownership boundary using `std.testing.allocator` and a deliberately freed temporary source buffer. It is imported by `src/pipeline.zig`, `src/scanner.zig`, `src/graph.zig`, `src/rag.zig`, and related files; it is not a root module in the build graph but is a direct dependency of most pipeline modules.

The confidence the file provides is high for the contracts it directly encodes: the closed `Status` and `RelationKind` vocabularies, the `pageLessThan` sort key, the `FrontmatterView` bounds constants, and the copy-on-promote ownership discipline. What it does not prove: that every call site correctly avoids storing source-buffer slices in a `DurablePage` (a convention enforced only by audit and documentation), that `PageDb.promote` handles every possible frontmatter override combination (relation duplication under id-override is covered partially), or that bounds constants are actually enforced by the parser (bounds are declared here as the single source of truth for `docs/contracts/frontmatter.md`, but the parser is a separate module).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Shared type and data-structure library |
| Conceptual domain | Content model: discovery, parse views, durable metadata |
| Build or test root | No — imported as a module by other root modules |
| Production runtime dependency | Yes — transitively compiled into the `boris` product binary via `pipeline.zig` and other callers |
| Expected execution command | `zig build test` (exercises inline tests); individual tests via `zig build test` selecting scanner, parser, or pipeline targets |
| Main collaborators | `src/identity.zig` (entity id derivation, `ContentKind`, bounds), `src/parser.zig` (consumes `FrontmatterView`, `Status`, `PageDb`), `src/scanner.zig` (produces `Page`, populates `PageList`), `src/graph.zig` (reads `DurablePage`, writes `role`/`index`/`parent_index`), `src/pipeline.zig` (orchestrates promote flow) |
| Documentation depth warranted | Medium-high — it is the canonical ownership contract for the compile session |

## Role in the Boris architecture

`src/page.zig` occupies the center of the Boris data pipeline. The scanner produces `Page` values (scan-time metadata only) and collects them into a `PageList`. After sorting via `sortPages`, the pipeline calls the parser on each file, which returns a `FrontmatterView` whose string fields are slices into the file's source buffer. The pipeline then calls `PageDb.promote` to copy all durable fields into the retain arena, producing a `DurablePage` stored in the `PageDb`. From that point forward, source buffers may be freed and the `PageDb` remains valid for the rest of the compile session.

The file is not linked exclusively into tests. It is a normal module dependency of production modules. It has no direct tie to `src/apex.zig` or the Apex C ABI — Markdown rendering is a separate concern handled downstream of `PageDb`. The file also has no relationship to the hostile C implementation (`apex_hostile.c`) or `src/apex_hostile_test.zig`.

The graph module reads `PageDb.items()` after the promote phase, assigns `role`, `index`, and `parent_index` to each `DurablePage` via `itemsMut()`, and freezes the structure before the emit phase. `src/page.zig` declares the graph fields (`role`, `index`, `parent_index`) as provisional until freeze, stable after — a documented but not mechanically enforced contract.
