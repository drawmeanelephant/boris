---
title: "`src/cli.zig` surface and execution"
id: docs/boris/src/cli/surface-and-execution
parent: docs/boris/src/cli
status: draft
tags: [boris, zig, source-reference, surface, cli]
---

# `src/cli.zig` surface and execution

## `Options` struct design

`Options` is the canonical parsed representation. Key design decisions:

- **String slices are views into argv.** Most `[]const u8` fields in `Options` point directly into the `args` slice passed to `parseOptions`. No copying occurs. This means `Options` must not outlive its source argv, and callers must not free argv while `Options` is live. This contract is enforced by convention, not by the type system.
- **One heap-allocated string: the theme path.** When `--theme ROOT` is used, `parseOptions` allocates the string `"{ROOT}/layouts/main.html"` via `std.fmt.allocPrint`. This is tracked by `owned_html_layout: bool`. `Options.deinit` checks this flag and frees the string when true. All other strings are views.
- **`targets` is heap-allocated.** `Options.targets` is a `std.ArrayListUnmanaged(target_mod.TargetSpec)`. `TargetSpec.layout_rules` is also heap-allocated when `--layout-rule` flags are present. `Options.deinit` iterates targets and frees `layout_rules` slices before calling `targets.deinit(gpa)`.
- **`null` versus default string.** Output directory fields (`out_dir`, `rag_dir`, `context_dir`, `llms_path`, `html_dir`) are typed as `?[]const u8` and are set to `null` in modes where they are not relevant. This allows callers to distinguish "not in this mode" from "defaulted to X". For example, `out_dir` is `null` in HTML mode even though `.boris` is the default IR output directory.

## Conflict matrix

The following pairwise conflicts are explicitly enforced (all produce `error.ConflictingFlags`):


| Combination | Rule |
| :-- | :-- |
| `--rag` + `--no-rag` | Bidirectional |
| `--no-rag` + `--rag-dir` | Bidirectional |
| Explicit `--out` + any RAG selection | Bidirectional |
| `--context` or `--context-dir` + RAG or IR | Any direction |
| `--llms` or `--llms-path` + RAG, IR, context, or HTML | Any direction |
| Explicit HTML flags + RAG, context, or explicit `--out` | Any direction |
| `--jobs`, `--watch`, or `--incremental` + IR or RAG or context | Any direction |
| `--target` + `--html-dir` | Any direction |
| Non-build command + any output/HTML/RAG/jobs/watch/incremental/theme/layout flag | Any direction |
| Build mode + `--format` or `--report` | Any direction |
| `--theme` + `--html-layout` | Any direction |

Conflicts are evaluated after the scan, not eagerly. Two flags may both be accepted during scanning and then rejected together in post-scan. This means partial state is accumulated before the error is detected.

## `execute` and `runArgs` dispatch

`execute(opts: Options, runner: anytype) ExitCode` is a comptime-polymorphic dispatcher:

- If `opts.help` is true: calls `runner.printHelp()`, returns `.success`, never calls `runner.run`.
- Otherwise: returns `runner.run(opts)`.

`runArgs(args, runner) u8` is the top-level shell entry:

1. Calls `parseOptions(gpa, args)` where `gpa` is extracted via `@hasField(@TypeOf(runner.*), "gpa")` — if the runner has a `gpa` field it is used, otherwise `std.testing.allocator` is the fallback. This extraction strategy is a heuristic and is potentially unsafe for production runners that do not carry a `gpa` field; the caller is responsible for ensuring the runner type carries the correct allocator.
2. On parse failure: calls `runner.reportUsage(err, bad)` if the runner has that declaration, otherwise falls back to `printParseError` + `printUsage`. Returns `ExitCode.usage.int()` (exit code 2).
3. On success: calls `execute(opts, runner)`, defers `opts.deinit(gpa)`, returns the exit code as `u8`.

## Ownership and allocation summary

| Allocation | Created by | Freed by | Notes |
| :-- | :-- | :-- | :-- |
| `targets` ArrayList | `targets.append(gpa, ...)` in parseOptions | `Options.deinit` | Also errdefer-freed in parseOptions on error |
| `target_layouts` ArrayList | `target_layouts.append(gpa, ...)` | `defer target_layouts.deinit(gpa)` inside parseOptions | Never escapes parseOptions |
| `pending_rules` ArrayList | `pending_rules.append(gpa, ...)` | `defer pending_rules.deinit(gpa)` inside parseOptions | Never escapes parseOptions |
| `TargetSpec.layout_rules` slice | `gpa.alloc(LayoutRule, count)` | `Options.deinit` iterates targets and frees | errdefer-freed on partial fill |
| `html_layout` (theme path) | `std.fmt.allocPrint` when `--theme` used | `Options.deinit` when `owned_html_layout` | errdefer-freed on post-scan error |
| All `[]const u8` string fields (other than html_layout) | Views into caller's `args` | Caller owns `args` | No copy, no free required |
