---
title: "`src/diagnostic.zig` evidence and cases"
id: docs/boris/src/diagnostic/evidence-and-cases
parent: docs/boris/src/diagnostic
status: draft
tags: [boris, zig, source-reference, evidence, diagnostic]
---

# `src/diagnostic.zig` evidence and cases

## Control flow (typical use)

```text
cli.parseOptions(argv)
    → ParseError  → main maps to ExitCode.usage (2)
    → Options
        → main.runPipeline / runHtml / runRag / …
            → pipeline.Result (ok, failure, diagnostics)
            → main maps failure + error diagnostics
                → ExitCode.success | content_error | io_error
            → process exit via ExitCode.int()
```

`RunResult` is available for stages that want a typed intermediate before calling `.exitCode()`, but the production path in `main.zig` may also return `ExitCode` directly after inspecting pipeline results. Both paths share the same numeric contract.

***

## Embedded tests

### `test "ExitCode values match contract"`

**Assertions:**

- `ExitCode.success.int() == 0`
- `ExitCode.content_error.int() == 1`
- `ExitCode.usage.int() == 2`
- `ExitCode.io_error.int() == 3`

**Evidence strength:** Directly demonstrated — pins the four contract integers.

**Residual gap:** Does not prove that `main` always returns these enums rather than raw integers; that is a caller concern.

### `test "FailureClass maps to ExitCode"`

**Assertions:**

- `.none` → `.success`
- `.content` → `.content_error`
- `.usage` → `.usage`
- `.io` → `.io_error`

**Evidence strength:** Directly demonstrated — full 1:1 mapping coverage.

**Residual gap:** Does not cover mapping from pipeline `FailureKind` or from `diag.countErrors` to `FailureClass`.

### `test "RunResult helpers"`

**Assertions:**

- `RunResult.success().exitCode() == .success`
- `RunResult.usage("bad flag").exitCode() == .usage`
- `RunResult.content("dup id").exitCode() == .content_error`
- `RunResult.io("read failed").exitCode() == .io_error`
- `RunResult.usage("bad flag").message.? == "bad flag"`

**Evidence strength:** Directly demonstrated for all four factories and one message round-trip.

**Residual gap:** Does not test `content` / `io` / `success` message field values (only `usage` message is checked). Does not test default field values of a zero-initialized `RunResult`. Does not test that `message` is not freed or duplicated (ownership is by documentation only).

***

## Build and test execution

From `build.zig` evidence inspected earlier:

- No standalone `diagnostic_mod` / `addTest` root for this file.
- Product `root_mod` uses `src/main.zig`, which imports `diagnostic.zig` (directly or via `cli.zig`).
- `b.addTest(.{ .root_module = root_mod })` therefore compiles and runs the three embedded tests in this file as part of `zig build test`.
- No renderer link requirement; no renderer options; no external library dependency.

**Production accidental use of a “hostile” double:** not applicable — this module has no C or engine dependency.

***
