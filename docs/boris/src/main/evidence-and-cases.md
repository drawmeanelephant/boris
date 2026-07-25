---
title: "`src/main.zig` evidence and cases"
id: docs/boris/src/main/evidence-and-cases
parent: docs/boris/src/main
status: draft
tags: [boris, zig, source-reference, evidence, cli, entrypoint]
---

# `src/main.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `test "runArgs: documented exit code mapping"` | Integration (CLI-only) | Verifies that valid flag combinations produce exit 0 and invoke the pipeline; invalid combinations produce exit 2 without invoking the pipeline | `SilentRunner`; various argv slices | `pipeline_calls` counts match; exit codes match | Flag parsing and conflict detection; runner dispatch |
| `test "ExitCode contract surface"` | Unit | Verifies that all four `ExitCode` integer values are exactly `{0,1,2,3}` | Direct `.int()` calls | `0`, `1`, `2`, `3` | `diagnostic.ExitCode` integer mapping |
| `test "mapHtmlError: multi-target I/O failure exits 3"` | Unit | Verifies `error.MultiTargetIoFailed` maps to `.io_error` | `quiet=true`, empty target list | `.io_error` | HTML error mapping |
| `test "mapHtmlError: target configuration failures exit 2"` | Unit | Verifies six target configuration errors map to `.usage` | `quiet=true`, one-element target spec | `.usage` for each | Target config → exit 2 contract |
| `test "runPipeline: valid fixture exits 0"` | Integration (filesystem) | Full IR pipeline over `docs/contracts/fixtures/valid/content` | Real gpa + io + tmpDir | `.success` | IR pipeline happy path |
| `test "runPipeline: duplicate-id exits 1"` | Integration (filesystem) | IR pipeline over `docs/contracts/fixtures/duplicate-ids/content` | Real gpa + io + tmpDir | `.content_error` | Duplicate-ID detection → exit 1 |
| `test "runPipeline: missing content root exits 3"` | Integration (filesystem) | IR pipeline over a non-existent path | Real gpa + io + tmpDir | `.io_error` | Missing root → exit 3 |
| `test "runPipeline: valid RAG fixture exits 0"` | Integration (filesystem) | RAG pipeline over `fixtures/content/valid` | Real gpa + io + tmpDir | `.success` | RAG pipeline happy path |
| `test "runPipeline: RAG invalid graph exits 1"` | Integration (filesystem) | RAG pipeline over duplicate-id fixture | Real gpa + io + tmpDir | `.content_error` | RAG pipeline content error |
| `test "runPipeline: HTML fixture exits 0"` | Integration (filesystem) | Full HTML build over `test/fixtures/html/content`; smoke-checks `index.html` exists | Real gpa + io + tmpDir | `.success`; `index.html` openable | HTML pipeline happy path; file existence |
| `test "runPipeline: HTML missing content root exits 3"` | Integration (filesystem) | HTML pipeline over non-existent path | Real gpa + io + tmpDir | `.io_error` | HTML missing root → exit 3 |
| `test "runPipeline: multi-target HTML build success and validation exits"` | Integration (filesystem) | Two-target HTML build; smoke-checks `index.html` in both output dirs | Real gpa + io + tmpDir; two `TargetSpec` values | `.success`; both `index.html` openable | Multi-target build; canonical sort |
| `test "runPipeline: multi-target path collision and content overlap exit 2"` | Integration (filesystem) | Three sub-cases: equal output roots; workspace escape; content/output overlap | Real gpa + io + tmpDir | `.usage` in all three cases | Target output validation → exit 2 |
| `test "parseOptions: HTML mode defaults and exclusive dirs"` | Unit (re-export) | Verifies `--html` defaults, bare-argv HTML default, `--out` → IR, and conflicting-flag errors | `std.testing.allocator`; various argv | Mode and dir fields; `error.ConflictingFlags` | `cli.parseOptions` re-export contract |
| `test { _ = @import("watch.zig"); }` | Transitive compilation | Forces `watch.zig` into the test binary | n/a | Compilation succeeds | Watch module included in test build |


***

## Control flow

```text
process start
    └── main(init: std.process.Init)
            argv conversion (arena allocator; → io_error on OOM)
            ProdRunner{gpa, io}
            cli.runArgs(argv, &runner)
                cli.parseOptions(gpa, argv)
                    → ParseError  →  runner.reportUsage(err, bad_arg)  →  return 2
                    → Options
                cli.execute(opts, &runner)
                    opts.help == true  →  runner.printHelp()  →  return 0
                    opts.help == false →  runner.run(opts)
                                              ↓
                                        ProdRunner.run
                                              ↓
                                        runPipeline(io, gpa, opts)
                                            opts.command != .build  →  runIntelligence
                                            opts.mode == .rag       →  runRag
                                            opts.mode == .context   →  runContext
                                            opts.mode == .llms      →  runLlms
                                            opts.mode == .html      →  runHtml
                                            opts.mode == .ir        →  pipeline.run inline
                                                                            → result.ok  →  return 0
                                                                            → result.failure → return 1 or 3
```

In tests using `SilentRunner`:

```text
cli.runArgs(argv, &silent_runner)
    cli.parseOptions(gpa, argv)
        → ParseError  →  silent_runner.reportUsage (no-op)  →  return 2
        → Options
    cli.execute(opts, &silent_runner)
        → silent_runner.run(opts)  →  pipeline_calls++  →  return 0
```
