---
title: "`src/main.zig` surface and execution"
id: docs/boris/src/main/surface-and-execution
parent: docs/boris/src/main
status: draft
tags: [boris, zig, source-reference, surface, cli, entrypoint]
---

# `src/main.zig` surface and execution

## Public API surface

All declarations marked `pub` are callable by tests and, in principle, by future harness code without invoking `main` itself.

| Symbol | Kind | Notes |
| --- | --- | --- |
| `ExitCode` | re-export of `diagnostic.ExitCode` | Four values: `.success` (0), `.content_error` (1), `.usage` (2), `.io_error` (3) |
| `Options` | re-export of `cli.Options` | Parsed flag struct; lifetime managed by caller |
| `Mode` | re-export of `cli.Mode` | Enum: `.ir`, `.rag`, `.context`, `.llms`, `.html` |
| `parseOptions` | re-export of `cli.parseOptions` | Pure flag parser; no I/O |
| `runPipeline` | `pub fn` | Core dispatch; maps `Options` to `ExitCode` |
| `runContext` | `pub fn` | Context-bundle export path |
| `runLlms` | `pub fn` | `llms.txt` export path |
| `runIntelligence` | `pub fn` | Read-only graph analysis; `check` and `impact` commands |
| `runRag` | `pub fn` | RAG corpus export path |
| `runHtml` | `pub fn` | HTML site render path; owns the watch loop |
| `runArgs` | `pub fn` | Silent-runner wrapper; used by tests |
| `main` | `pub fn` | Zig 0.16 `std.process.Init`-based entry |

`mapHtmlError` and the internal rendering helpers (`renderAnalysisHuman`, `renderAnalysisJson`, `appendFmt`, `BufferWriter`) are private (`fn`).

***

## Exit-code contract

The contract is expressed concisely in a comment above `runPipeline` and is directly tested by `test "ExitCode contract surface"`:

| Code | Value | Meaning |
| --- | --- | --- |
| `.success` | 0 | All validation passed; output written |
| `.content_error` | 1 | Content validation failure (duplicate IDs, bad graph, parse failure, layout marker errors, etc.) |
| `.usage` | 2 | Flag conflict, unknown flag, missing value, target configuration error, workspace escape |
| `.io_error` | 3 | Filesystem, process argument, or system-level failure |

`mapHtmlError` maps the richer Zig error set from the HTML path to these four codes. The default `else` arm of its `switch` maps any unrecognized error to `.io_error`. That default is the only branch not enumerated in the test coverage for `mapHtmlError`.

***

## Dispatch logic

`runPipeline` is the single entry from `ProdRunner.run`. Its dispatch order is:

```text
runPipeline(io, gpa, opts)
    if opts.command != .build  →  runIntelligence
    else switch opts.mode:
        .rag     →  runRag
        .context →  runContext
        .llms    →  runLlms
        .html    →  runHtml
        .ir      →  (falls through to inline IR pipeline block)
```

The inline IR block calls `pipeline.run` and maps its result. Every other mode arm is a tail call to a named function. All branches return `ExitCode`; none propagate Zig errors to the caller — all `catch` clauses at the pipeline boundary convert errors to `.io_error` and optionally print to stderr.

`runIntelligence` is unusual in that it calls `pipeline.compile` (not `pipeline.run`) to intentionally avoid emitting any output artifacts. This is documented in a comment: "Read-only graph analysis. This intentionally calls pipeline.compile rather than pipeline.run, so no IR/RAG/HTML artifacts or cache manifests publish."

***
