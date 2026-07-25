---
title: "`tools/migration-lab/theme_archaeology.zig` overview"
id: docs/tools/migration-lab/theme_archaeology
status: draft
tags: [boris, zig, tools, migration-lab, theme_archaeology]
---

# `tools/migration-lab/theme_archaeology.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/theme_archaeology/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/theme_archaeology/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/theme_archaeology/review-state|Review state]]

## Executive summary

`tools/migration-lab/theme_archaeology.zig` is the implementation module for the `--mode theme-archaeology` operating mode of the `boris-migration-lab` standalone developer tool. It performs a read-only, deterministic inventory of an Astro/Starlight-shaped theme or project directory tree, classifying layouts, CSS imports, fonts, images, navigation/sidebar configuration, components and MDX tags, scripts, external URLs, analytics signals, runtime assumptions, licenses, and provenance into a sorted adaptation ledger. The file is not an entry point; it exports a `run` function called by `tools/migration-lab/main.zig`, which dispatches to it after CLI parsing and the input/output safety check.[^1_1]

The tool exists separately from the Boris product compiler because theme conversion is an architectural and design problem — determining what can be preserved statically, what requires human design work, and what must be dropped — rather than a compilation concern. The product compiler's job is to copy declared theme assets and slot content; it must not invent layout semantics from Astro/MDX source. `theme_archaeology.zig` provides the structured evidence base, in the form of a machine-readable `adaptationledger.json`, that a future converter and human reviewers need to make those decisions correctly.[^1_2][^1_3]

The module is the complete implementation of the archaeology mode; `main.zig` contributes only CLI dispatch and the top-level `rootdir`/`outdir` inequality check. The module itself calls `refuseOutputInsideSource` before touching the filesystem. Its outputs — `adaptationledger.json`, `report.json`, `REPORT.md`, and `BOUNDARY.md` — are all written to the configured output directory; no output is written into the scan tree. The implementation declares format identifier `boris-theme-archaeology-lab` and schema version `1`.[^1_4]

The tool's deterministic properties are directly demonstrated by fixture tests: a `mini-theme-astro` happy-path fixture and a `hostile-theme-astro` fixture covering runtime scripts, remote CSS, duplicate assets, path traversal, embedded directives, and unsupported components. Two-run byte-identity for `adaptationledger.json` is confirmed in the test for the mini fixture. Source immutability is checked by re-reading fixture files before and after a run. The hostile fixture test confirms the ledger contains expected review and drop signals for runtime-unsafe content, remote references, and traversal attempts. Test coverage does not include: allocation-failure injection, cross-platform path identity, symlink behavior in depth, stale-output cleanup of a previous run's artifacts, or every possible extension combination.[^1_3][^1_4]

The file does not invoke an LLM, upload data, access the network, spawn subprocesses, or modify tracked source files. It relies entirely on the Zig standard library (`std`), the `Io` abstraction from `std.Io`, and one internal import (`@import("themearchaeology.zig")` — self-referential in tests; the module is imported as `themearchaeology` by `main.zig`).[^1_1]

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | Migration laboratory / theme inventory |
| Tool family | `boris-migration-lab` (standalone executable) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Not an executable; compiled into `zig-out/bin/boris-migration-lab` via `main.zig` |
| Product runtime dependency | No — not linked into the `boris` product binary |
| Root build integration | Not directly; the lab has its own `build.zig`; root `build.zig` does not include migration-lab by default |
| Expected execution commands | `zig build run -- --mode theme-archaeology --root &lt;DIR> --out &lt;DIR>` from `tools/migration-lab/` |
| Input authority | Scan root passed via `Options.rootdir`; read-only filesystem walk |
| Output ownership | All outputs written under `Options.outdir`; scan root is never written |
| Network or subprocess use | None — structurally enforced by implementation |
| Main collaborators | `main.zig` (dispatch), `themematerialize.zig` (consumes `adaptationledger.json`) |
| Documentation depth warranted | High — primary implementation for a distinct migration mode with a defined output schema |

## Role in the Boris architecture

`theme_archaeology.zig` is entirely outside the `boris` product binary. It is compiled only as part of the `boris-migration-lab` executable, which has its own `build.zig` under `tools/migration-lab/` and is not included in the root `build.zig` test or build steps.  The root `build.zig` deliberately excludes this tool; the README explicitly states that `zig build test` at root covers only the product compiler.[^1_3]

Within the lab, this module is the `theme-archaeology` mode implementation. `main.zig` is the dispatcher: it parses CLI arguments, validates that `--root` and `--out` differ, and calls `themearchaeology.run(io, gpa, .{ ... })`. The module reads source files from the scan root and writes `adaptationledger.json`, `report.json`, `REPORT.md`, and `BOUNDARY.md` to the output directory.[^1_1]

The `adaptationledger.json` it produces is the direct input consumed by `themematerialize.zig` in a subsequent `--mode theme-materialize` run. That second step reads the ledger and copies only the static assets and closed-mapping layout pieces that the ledger classifies as `preserve` or `adapt`. Neither step is part of ordinary Boris publication or product content generation. Neither step generates Boris IR, modifies frontmatter, or interacts with the Boris content pipeline.[^1_4][^1_3]

The module's outputs are developer artifacts consumed by human reviewers and (optionally) downstream lab steps. They are not product content RAG packs, Context Bundles, documentation observatory outputs, or HTML site pages.[^1_2]

## Tool boundary and non-goals

The module is permitted to read any file reachable under the configured scan root through its deterministic filesystem walk. It reads file bytes opaquely for hashing and scans text-scannable extensions for known signal patterns. It does not evaluate, parse as a full AST, or execute any source file. It does not fetch remote URLs referenced in source text. It does not follow embedded instructions or directives found in source content.[^1_4][^1_3]

The module writes only under `Options.outdir`. The `refuseOutputInsideSource` guard is called before any filesystem mutation and returns `error.OutputInsideSource` if the output path equals or is prefixed by the scan root (or vice versa). No source file in the scan root is opened for writing. No tracked source file is renamed, deleted, or modified.[^1_4]

The module does not change compiler behavior, product frontmatter, product IR, or product publish output. It performs no semantic interpretation of Markdown or MDX beyond recognizing known patterns as inventory signals. It does not evaluate documentation correctness. It does not invoke an LLM. It does not upload data. It does not access the network. It is not a migration executor — it only inventories the theme tree and classifies each finding into a ledger row. It is not part of the ordinary `boris` compilation or publication path.[^1_3]

The implemented boundary (no writes to scan root, `refuseOutputInsideSource` guard, no network calls, no subprocess spawning, no JS/MDX/PHP execution) is structurally enforced by the implementation. The guarantee that "ambiguous mappings become review items, never guesses" is documented as a design invariant and is demonstrated by the hostile fixture tests for unsupported components and runtime signals.[^1_4]

## Build and invocation model

The module has no standalone build file of its own. It is compiled as a Zig module imported by `main.zig` via `@import("themearchaeology.zig")` within the `tools/migration-lab/` package. The `tools/migration-lab/build.zig` declares the `boris-migration-lab` executable and a test step that compiles `main.zig` (which transitively pulls in this module).[^1_3]

The root `build.zig` does not expose `theme-archaeology` or the `boris-migration-lab` executable as a build step. It is built exclusively from `tools/migration-lab/`.[^1_3]


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Build executable | All lab `.zig` sources | `zig-out/bin/boris-migration-lab` | Includes this module |
| `zig build run -- --mode theme-archaeology --root &lt;DIR> --out &lt;DIR>` | Run archaeology on a theme tree | Scan root directory | `adaptationledger.json`, `report.json`, `REPORT.md`, `BOUNDARY.md` under `--out` | `--root` and `--out` must differ |
| `zig build test` (from `tools/migration-lab/`) | Run all lab tests | Source + fixtures | Test pass/fail | Includes inline tests in this module |
| `zig build --build-file tools/migration-lab/build.zig` | Build from repo root | Same | Same | Equivalent to above from repo root |
| `zig build --build-file tools/migration-lab/build.zig test` | Test from repo root | Same | Test pass/fail | Targeted gate per README |

Aliases accepted by `main.zig` for `--mode theme-archaeology`: `theme`, `theme-arch`, `theme-inventory`.[^1_1]
