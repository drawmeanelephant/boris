---
title: "`src/main.zig` overview"
id: docs/boris/src/main
status: draft
tags: [boris, zig, source-reference, cli, entrypoint]
---

# `src/main.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/main/surface-and-execution|Surface and execution]]
* [[docs/boris/src/main/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/main/review-state|Review state]]

## Executive summary

`src/main.zig` is the top-level product entry point and the primary integration layer for the Boris binary. It serves two simultaneous roles that are separated by compilation context but coexist in the same file: the `main` function consumed by the Zig build system as the executable root, and a suite of integration tests that exercise the fully assembled pipeline through the same public function surface used at runtime.

The file's central responsibility is translating a parsed `cli.Options` value into an exit code by dispatching across five build modes (IR, RAG, context, `llms.txt`, HTML) and two read-only analysis commands (`check`, `impact`). Each dispatch arm calls into a dedicated backend module (`pipeline`, `rag`, `context`, `llms`, `compile`, `intelligence`) and maps structured results or Zig error values to one of four documented exit codes (0 success, 1 content error, 2 usage error, 3 I/O error). The mapping is implemented in `runPipeline` and `mapHtmlError`; neither function prints anything when the `quiet` flag is set, preserving the contract that exit codes and output artifacts fully represent build status without requiring stderr parsing.

The file exists to keep the `main` function thin and testable. Rather than letting `main` directly invoke pipeline logic, all reachable code paths flow through `ProdRunner`, a concrete value type satisfying the duck-typed runner interface defined in `cli.runArgs`. `SilentRunner`, a parallel stub defined in the same file, allows CLI parsing and flag-conflict tests to run without touching the filesystem or triggering real compilation. Integration tests that do exercise the real pipeline use `runPipeline` directly with real allocators, a `std.testing.io` I/O handle, and temporary directories created via `std.testing.tmpDir`.

The file is executed as the build root of the `boris` executable step (inferred from the module-file placement; confirmed by `pub fn main(init: std.process.Init) u8` matching Zig 0.16 `std.process.Init`-based entry convention). It is also compiled as a test root, because it ends with inline `test` blocks and the trailing `test { _ = @import("watch.zig"); }` transitive declaration, which pulls the watch module into the test compilation unit. The inline tests do not require a network, external process, or custom C library; they run with `zig build test` under the standard test step.

What this file does not prove: it does not test `render.zig` or the Markdown-to-HTML rendering path in depth — the HTML integration tests only smoke-check that an `index.html` was written at the expected path. It does not cover incremental build correctness, watch-mode event delivery, multi-job parallel rendering, or theme-asset fingerprinting. No test here exercises the `--textile` input format with the HTML pipeline. The `runIntelligence` function is covered only by the `SilentRunner` dispatch path (via `runArgs`), not by a direct call with fixture content.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production executable entry point + integration test root |
| Conceptual domain | CLI dispatch, pipeline orchestration, exit-code contract |
| Build or test root | Both: `main` entry for the `boris` binary; inline `test` blocks executed under `zig build test` |
| Production runtime dependency | Yes — this file is the root compilation unit of the shipped binary |
| Expected execution command | `zig build` (production); `zig build test` (test suite) |
| Main collaborators | `cli.zig`, `pipeline.zig`, `rag.zig`, `context.zig`, `llms.zig`, `compile.zig`, `intelligence.zig`, `target.zig`, `theme.zig`, `json_out.zig`, `watch.zig`, `diagnostic.zig` |
| Documentation depth warranted | High — it is the only file that owns the exit-code contract and the CLI-to-pipeline dispatch surface |

***

## Role in the Boris architecture

`src/main.zig` sits at the outermost layer of the Boris call stack. It is the file the Zig build system lists as the root source of the `boris` executable step. Everything it imports (`pipeline`, `rag`, `compile`, `intelligence`, etc.) is compiled into the production binary along with it; nothing in this file is conditionally excluded from the production build.

Its relationship to `src/cli.zig` is asymmetric and deliberate. `cli.zig` is responsible for parsing argv into a typed `Options` value without touching the filesystem or knowing about pipelines. `main.zig` imports that result and performs the actual work. `cli.runArgs` is generic over a runner interface: in production the runner is `ProdRunner` (defined here), which calls `runPipeline`; in CLI-only tests it is `SilentRunner` (also defined here), which increments a counter and returns success. This design means the full conflict-detection and flag-parsing logic in `cli.zig` is tested independently of any filesystem interaction.

`src/render.zig` is not directly imported by `src/main.zig`; the Oliver-backed rendering seam is reached through `compile.zig` → `compile.compileHtmlSite` / `compileHtmlSiteMulti`, which is only invoked from the `runHtml` branch.

The watch subsystem (`watch.zig`) is imported only lazily inside `runHtml` under an `opts.watch` branch (`const watch = @import("watch.zig")`). The final `test { _ = @import("watch.zig"); }` declaration ensures the watch module is included in the test build even though it is a lazy import in production.

***
