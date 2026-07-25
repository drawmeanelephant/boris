---
title: "`tools/migration-lab/theme_materialize.zig` overview"
id: docs/tools/migration-lab/theme_materialize
status: draft
tags: [boris, zig, tools, migration-lab, theme_materialize]
---

# `tools/migration-lab/theme_materialize.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/theme_materialize/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/theme_materialize/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/theme_materialize/review-state|Review state]]

## Executive summary

`tools/migration-lab/themematerialize.zig` is the implementation module for the `theme-materialize` mode of the `boris-migration-lab` standalone developer tool. It is not an entry point; it is invoked exclusively through `tools/migration-lab/main.zig`, which dispatches to `themematerialize.run(io, gpa, opts)` after CLI parsing. The file has no `main` function and exports no public CLI surface of its own.

The module supports a specific developer workflow: after a human has run `theme-archaeology` to produce an `adaptationledger.json` over an Astro/Starlight-shaped theme source tree, this module consumes that ledger and emits a narrowly scoped Boris theme draft — copying only static assets whose ledger decision is `preserve` and whose source file has no companion `drop`-flagged evidence, and generating a single closed static HTML layout shell for approved `adapt` layout rows. It does not execute Astro, JavaScript, MDX, PHP, or any build system, and it never modifies the source tree. The tool exists separately from the Boris product compiler because theme conversion is a design problem involving nav graph, component vocabulary, and trusted layout HTML; the product compiler is deliberately fail-closed and must not invent layout semantics from Astro/MDX source.

`themematerialize.zig` is the complete implementation of the `theme-materialize` mode. It contains path-safety helpers, ledger parsing, asset copy logic with SHA-256 verification, layout HTML emission, and report/manifest serialization. The `run` function is the single public entry point, called with an arena-backed allocator and an `Io` abstraction. It reads the archaeology ledger as JSON, iterates ledger entries, applies a multi-gate refusal policy to each, copies approved static assets byte-for-byte, and emits `materialize-manifest.json`, `MATERIALIZE-REPORT.md`, and `PROVENANCE.md` under the configured output directory.

Determinism is structurally enforced: the ledger is processed in the order it was written by `theme-archaeology` (which sorts by source path), per-field JSON serialization uses a fixed key order, and no host timestamps or random identifiers appear in outputs. The SHA-256 recorded in the ledger is verified against the actual source file bytes before copying; a mismatch causes an explicit `refused` status rather than a silent copy. Two inline Zig tests provide direct evidence: a full determinism test using the `mini-theme-astro` fixture (runs twice, compares every named output byte-for-byte), and a hostile-fixture test verifying that stylesheets with remote-import or traversal evidence are refused and not written to the output directory.

What the tests do not cover: cross-platform path separator behavior, allocation failure paths, output directory creation failure, partial-write cleanup, behavior on very large source files, and CLI argument edge cases (all CLI handling lives in `main.zig`).

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | Theme migration / Boris theme draft materialization |
| Tool family | `boris-migration-lab` (standalone, under `tools/migration-lab/`) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Module imported by `main.zig`; executable is `zig-out/bin/boris-migration-lab` |
| Product runtime dependency | No — not linked into the `boris` product binary |
| Root build integration | Not included in root `build.zig` test step; accessed only via `tools/migration-lab/build.zig` |
| Expected execution commands | `zig build run -- --mode theme-materialize --root <tree> --ledger <ledger.json> --out <dir>` |
| Input authority | Read-only: source theme tree and `adaptationledger.json` from a prior `theme-archaeology` run |
| Output ownership | All writes go exclusively under `--out`; source tree is never modified |
| Network or subprocess use | None (structurally: no `std.process.exec`, no `std.net` usage observed in source) |
| Main collaborators | `themearchaeology.zig` (imports `refuseOutputInsideSource`, `sha256Hex`), `main.zig` (dispatch), `Io` abstraction |
| Documentation depth warranted | Moderate — focused on refusal policy, path safety, and deterministic artifact contract |


***

## Role in the Boris architecture

`themematerialize.zig` is entirely outside the `boris` product binary. It is compiled only as part of the `boris-migration-lab` executable produced by `tools/migration-lab/build.zig`. The root `build.zig` does not include this file or its test step; the README explicitly states that `zig build test` from the repo root covers only the product compiler and deliberately excludes this laboratory.

The file sits in the second of a deliberate two-step theme workflow:

1. `theme-archaeology` (`themearchaeology.zig`) — read-only inventory, produces `adaptationledger.json`
2. `theme-materialize` (`themematerialize.zig`) — ledger-driven safe draft emission, produces a Boris theme skeleton

It reads Boris source files (the theme source tree) only as opaque bytes for copying — it performs no semantic interpretation, no frontmatter evaluation, and no Boris IR access. It produces output under a configured output directory that a human can inspect and pass to the Boris product compiler as a theme, but the materialized theme is explicitly described as a starting point for human review, not a finished product.

The module is:

- **compiled as part of a separate executable** (`boris-migration-lab`);
- **not linked into production**;
- **not imported by any other tool**;
- **not used as a test root** on its own (its tests are compiled through the `main.zig` test block that pulls in `themematerialize`);
- **not exposed through the root build** as a convenience step.

It has no relationship to the source-RAG tool, Context Bundles, product content RAG, JSON IR output, or migration laboratories other than the two-step theme workflow.

***

## Tool boundary and non-goals

| Boundary | Implemented | Merely documented |
| :-- | :-- | :-- |
| Never writes to source tree | Structurally enforced — all writes go to `output` dir opened from `opts.outdir`; `refuseOutputInsideSource` is called before any I/O | Also documented in README |
| No network access | Structurally: no `std.net` import or use observed | Also documented in README |
| No subprocess invocation | Structurally: no `std.process.exec` or equivalent observed | Also documented in README |
| No JS/MDX/PHP/Astro execution | Structurally: no runtime invocation; source files read as opaque bytes only | Documented as hard boundary |
| Never modifies tracked source | Structurally enforced; source dir opened read-only | Documented |
| No semantic interpretation | No frontmatter parsing; ledger fields consumed as strings, not evaluated | Design intent |
| No LLM invocation | No evidence of any LLM API call | N/A |
| No upload | No network, no upload | N/A |
| Not on `boris` execution path | Not in root `build.zig`; not imported from `src/` | Build evidence |
| Refuses duplicate destinations | Structurally: `destinations` list checked before each copy | Tested (hostile fixture) |
| Refuses unsafe paths | `isSafeRelativePath` checked on both source paths and destinations | Tested explicitly |
| SHA-256 verification before copy | Structurally: ledger SHA compared to actual file SHA before write | Tested (determinism test) |

The tool does **not** evaluate documentation correctness, change compiler behavior, change product frontmatter or IR, perform any conversion of dynamic theme behaviors, or act as a general migration tool for content.

***

## Build and invocation model

`themematerialize.zig` has no standalone build file. It is compiled as part of the `boris-migration-lab` executable declared in `tools/migration-lab/build.zig`. Its tests are included via the `test { _ = @import("themematerialize.zig"); }` block in `main.zig`.


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Build the executable | All `.zig` sources under `tools/migration-lab/` | `zig-out/bin/boris-migration-lab` | Requires Zig 0.16 |
| `zig build test` (from `tools/migration-lab/`) | Run all tests including `themematerialize` tests | Source + fixture directories | Test pass/fail | Runs inline tests in `themematerialize.zig` via `main.zig` pull-in |
| `zig build run -- --mode theme-materialize --root <src> --ledger <ledger.json> --out <dir>` | Execute theme materialization | Source theme tree, ledger JSON | Theme draft, manifest, reports | Ledger must be from a prior `theme-archaeology` run |
| `zig build --build-file tools/migration-lab/build.zig run -- --mode theme-materialize ...` | Same, from repo root | As above | As above | Root aggregate gate form |

No generated artifacts are prerequisites for building `themematerialize.zig` itself. The ledger is a runtime input, not a build-time input.

***
