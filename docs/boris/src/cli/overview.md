---
title: "`src/cli.zig` overview"
id: docs/boris/src/cli
status: draft
tags: [boris, zig, source-reference, cli]
---

# `src/cli.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/cli/surface-and-execution|Surface and execution]]
* [[docs/boris/src/cli/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/cli/review-state|Review state]]

## Executive summary

`src/cli.zig` is the typed command-line interface layer for Boris. Its single responsibility is to parse a raw `[]const []const u8` argv slice into a canonical, heap-safe `Options` value, and to provide the execution dispatch wiring that connects parsed options to the build pipeline. It deliberately does not open files, read configuration, consult environment variables, or touch the filesystem in any way; those responsibilities belong entirely to downstream pipeline modules.

The file exists because Boris has a non-trivial and growing public surface — five output modes (`ir`, `rag`, `context`, `llms`, `html`), three commands (`build`, `check`, `impact`), multi-target HTML configurations, per-target layout paths, rule-based layout selectors, a theme sugar flag, parallel rendering knobs, and an incremental watch mode — and all of that surface must be parsed, validated for mutual conflicts, and reduced to a single deterministic `Options` struct before any I/O occurs. Isolating this logic in one file makes it independently testable and prevents parse and conflict logic from leaking into the pipeline.

`parseOptions` is the core function. It performs a single linear scan of argv, maintaining a set of boolean `saw_*` flags per recognized option to enforce duplicate detection. After the scan it applies a post-scan conflict matrix and mode-selection logic in a fixed priority order: explicit HTML flags → RAG → context → llms → IR → HTML default. Targets, target-layout assignments, and layout rules are collected during the scan and cross-referenced against each other after mode selection. The final `Options` value contains string slices that are views into the original argv array (not copies), with the single exception of the `--theme`-synthesized layout path, which is heap-allocated and tracked by `owned_html_layout`.

The file also provides `execute`, a thin dependency-injection wrapper that routes a parsed `Options` to a caller-supplied `runner`, and `runArgs`, a convenience entry point that composes `parseOptions`, error reporting, and `execute` in sequence. The injectable `runner` interface (`printHelp`, `run`, `reportUsage`) is verified by the test spy pattern. `printUsage` and `printParseError` are standalone display helpers using `std.debug.print`.

The test suite is large and directly embedded. It covers: default mode selection; all five modes and their flag combinations; every conflict pair in the conflict matrix (over 50 cases in the table test alone); duplicate-flag detection for every boolean and value-taking option; empty-value and missing-value sentinel cases; help short-circuit behavior; watch/incremental implication; target parsing and target-layout binding; layout-rule parsing, canonicalization, and conflict detection; layout path security validation (rejecting `..`, absolute paths, and backslash escapes); `--theme` sugar composition; `--llms` and `--llms-path`; `execute` and `runArgs` via spy runners; `findBadArg` output; and target-order canonicalization (demonstrating that `--target` argv permutations produce the same sorted `Options.targets`).

The file does not prove: that the pipeline correctly interprets every `Options` field; that `Options.deinit` is always called in production paths (callers own this responsibility); that `runArgs`'s `gpa` extraction heuristic (`@hasField`) is safe for all runner types; or that conflict rules are complete with respect to all future flag combinations.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production module with embedded unit tests |
| Conceptual domain | CLI parsing; argument validation; mode selection; execution dispatch |
| Build or test root | Compiled into the production binary; tests run via `zig build test` |
| Production runtime dependency | Yes — entry point for all Boris invocations |
| Expected execution command | `zig build test` (tests); `zig build` (production); production binary invoked as `boris [options]` |
| Main collaborators | `src/diagnostic.zig` (`ExitCode`, `RunResult`), `src/target.zig` (`TargetSpec`, `isValidTargetName`, `sortTargetSpecsByName`), `src/layout_select.zig` (`validateLayoutPath`, `parseSelector`, `rejectDuplicateSelectors`, `sortRulesCanonical`, `LayoutRule`, `SelectorKind`, `max_rules_per_target`), `src/identity.zig` (`InputFormat`) |
| Documentation depth warranted | High — the public CLI surface is the primary operator contract for Boris |

## Role in the Boris architecture

`src/cli.zig` is the first module executed by the Boris binary after startup. It takes raw OS-supplied argv and produces the typed `Options` value that the pipeline consumes. It has no dependency on any content-parsing, graph, caching, or rendering module; it only needs type definitions from `target.zig`, `layout_select.zig`, `identity.zig`, and `diagnostic.zig`.

The production binary links `cli.zig` unconditionally. There are no compile-time feature flags controlling its inclusion. It is not test-only. The `runArgs` function is the intended binary entry point: it calls `parseOptions`, dispatches through `execute`, and returns a `u8` exit code directly usable as a process exit value.

`src/render.zig` and the Oliver-backed rendering seam are entirely downstream of this file; `cli.zig` does not reference them. The file is similarly independent of `src/cache.zig`, `src/graph.zig`, and all I/O modules.

The test suite runs inline with `zig build test`. No test double, hostile C implementation, or special build target is needed; all tests exercise pure Zig logic operating on static argv slices and the `std.testing.allocator`.
