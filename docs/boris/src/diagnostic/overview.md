---
title: "`src/diagnostic.zig` overview"
id: docs/boris/src/diagnostic
status: draft
tags: [boris, zig, source-reference, diagnostic]
---

# `src/diagnostic.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/diagnostic/surface-and-execution|Surface and execution]]
* [[docs/boris/src/diagnostic/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/diagnostic/review-state|Review state]]

## Executive summary

`src/diagnostic.zig` is a small, leaf-level production library that defines the process exit-code model for the Boris product CLI. It provides three coordinated abstractions: an `ExitCode` enum (`u8`-backed) with the four contract values `0` success, `1` content error, `2` usage, and `3` I/O error; a `FailureClass` enum that classifies high-level failure kinds and maps them to exit codes; and a `RunResult` struct that pairs a failure class with an optional human-readable message and offers factory helpers for each class.

The file exists because Milestone 3 introduced a typed CLI with stable process exit codes, and the normative contract in `docs/contracts/diagnostics.md` freezes those four numeric values for CI, scripts, and tooling. Content-level diagnostic codes (`EDUPLICATEID`, `EFRONTMATTER`, and the rest) live in `src/diag.zig`. This module deliberately does **not** own those codes; its module-level doc comment states that it only maps high-level failure classes to process exit status. Keeping the two concerns separate prevents CLI exit logic from depending on the full diagnostic type system and allows the exit model to be tested in isolation.

`src/diagnostic.zig` is imported by `src/cli.zig` (which re-exports `ExitCode` and `RunResult`) and by `src/main.zig` (which uses those types for the production runner). It has no imports beyond `std`, no Apex link, and no `build_options`. It is not a standalone module root in `build.zig`; its three embedded tests execute when any importing module root is compiled under `zig build test`.

The confidence this file provides is high relative to its size: the three tests directly demonstrate that every `ExitCode` integer matches the contract, that every `FailureClass` maps to the correct `ExitCode`, and that every `RunResult` factory produces the expected exit code and message. What it does not prove is that the production CLI always classifies real failures into the correct `FailureClass` — that mapping is the responsibility of `main.zig` / `pipeline.zig` callers. It also does not own or format content diagnostics; those remain in `diag.zig`.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production shared library module with embedded unit tests |
| Conceptual domain | Process exit codes and CLI result model |
| Build or test root | None standalone; compiled transitively via `src/cli.zig` and `src/main.zig` |
| Production runtime dependency | Yes — imported by CLI and product entry |
| Expected execution command | `zig build test` (tests run as part of importing module roots) |
| Main collaborators | `src/cli.zig` (re-exports `ExitCode` / `RunResult`), `src/main.zig` (exit mapping), `src/diag.zig` (content diagnostics — sibling, not imported), `docs/contracts/diagnostics.md` (normative exit table) |
| Documentation depth warranted | Medium — the module is small and deliberate; exit-code contract alignment is the critical surface |


***

## Role in the Boris architecture

`src/diagnostic.zig` sits below the CLI parser and above the process exit boundary. It has no imports from other Boris modules — only `std` — so it is a true leaf. Callers import it to obtain typed exit values rather than scattering magic integers through `main.zig`.

Relative to the product binary, the module is compiled into `boris` via `root_mod` → `main.zig` → `cli.zig` / `diagnostic.zig`. There is no dedicated `diagnostic_mod` or `diagnostic_tests` artifact in `build.zig`; tests ride along with the modules that import this file (notably the unit-test root based on `src/main.zig` and any other root that pulls in `cli.zig`).

Relative to `src/diag.zig`, the separation is intentional and documented in this file's header:

- **`diag.zig`**: content-level diagnostics — severity, closed codes (`EDUPLICATEID`, …), `Diagnostic` structs, text formatting, sort, error counting.
- **`diagnostic.zig`**: process-level exit status — which integer the OS process returns after a CLI dispatch.

The two modules do not import each other. Mapping from a pipeline `Result` (with `diag.Diagnostic` list and a pipeline-local failure kind) to a process `ExitCode` is performed in `main.zig` / `pipeline` consumers, not here.

Relative to `docs/contracts/diagnostics.md`, the exit-code table (0 / 1 / 2 / 3) is the normative counterpart of `ExitCode`. Severity and content codes in that same contract document are implemented by `diag.zig`, not this file.

Relative to Apex and hostile ABI tests, this file has no relationship.

***
