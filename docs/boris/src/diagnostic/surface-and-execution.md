---
title: "`src/diagnostic.zig` surface and execution"
id: docs/boris/src/diagnostic/surface-and-execution
parent: docs/boris/src/diagnostic
status: draft
tags: [boris, zig, source-reference, surface, diagnostic]
---

# `src/diagnostic.zig` surface and execution

## Data model

### `ExitCode`

```zig
pub const ExitCode = enum(u8) {
    success = 0,
    content_error = 1,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};
```

A `u8`-backed enum so the discriminant is exactly the process exit status. The `int()` method is the single conversion path from typed value to the integer returned to the OS.


| Variant | Integer | Contract meaning (`docs/contracts/diagnostics.md`) |
| :-- | :-- | :-- |
| `success` | `0` | Validation passed; IR/HTML/RAG completed with zero `error` diagnostics |
| `content_error` | `1` | One or more content / validation `error` diagnostics |
| `usage` | `2` | CLI usage / flag error (`EUSAGE`) |
| `io_error` | `3` | I/O or system failure (`EIO`) |

The integer assignments are fixed by the contract. Renaming a variant without changing the `= N` assignment would not change exit status; changing the assignment without a contract amendment would break CI and scripts. The embedded test pins the four integers explicitly.

### `FailureClass`

```zig
pub const FailureClass = enum {
    none,
    content,
    usage,
    io,

    pub fn exitCode(self: FailureClass) ExitCode {
        return switch (self) {
            .none => .success,
            .content => .content_error,
            .usage => .usage,
            .io => .io_error,
        };
    }
};
```

A high-level classification used by the CLI and pipeline stages before a concrete `ExitCode` is chosen. The four variants map 1:1 onto the four `ExitCode` values via `exitCode()`.

**Note on naming vs pipeline:** `src/pipeline.zig` defines its own `FailureKind` enum (`none`, `content`, `io`) without a `usage` variant, because usage errors are rejected in the CLI parser before the pipeline runs. `FailureClass` here is the broader CLI-facing model; it is not the same type as pipeline `FailureKind`. Callers must map between them explicitly (e.g. in `main.zig`).

### `RunResult`

```zig
pub const RunResult = struct {
    class: FailureClass = .none,
    message: ?[]const u8 = null,

    pub fn success() RunResult { ... }
    pub fn usage(message: []const u8) RunResult { ... }
    pub fn content(message: []const u8) RunResult { ... }
    pub fn io(message: []const u8) RunResult { ... }

    pub fn exitCode(self: RunResult) ExitCode {
        return self.class.exitCode();
    }
};
```

A controlled result from a CLI dispatch or pipeline stage. Fields:


| Field | Type | Role |
| :-- | :-- | :-- |
| `class` | `FailureClass` | High-level outcome; defaults to `.none` |
| `message` | `?[]const u8` | Optional human text; **not owned** — caller retains lifetime (documented in source) |

Factory helpers:


| Helper | `class` | `message` |
| :-- | :-- | :-- |
| `success()` | `.none` | `null` |
| `usage(msg)` | `.usage` | `msg` |
| `content(msg)` | `.content` | `msg` |
| `io(msg)` | `.io` | `msg` |

`exitCode()` delegates entirely to `self.class.exitCode()`. The message never affects the exit integer; it exists only for optional human reporting by callers.

**Ownership:** `message` is a borrowed slice. `RunResult` performs no allocation and holds no allocator. Callers that allocate a message string must free it themselves after the result is consumed (or use a long-lived arena / static string).

***

## Free functions and methods summary

| Declaration | Kind | Purpose |
| :-- | :-- | :-- |
| `ExitCode.int` | method | `@intFromEnum` → `u8` for process exit |
| `FailureClass.exitCode` | method | Map class → `ExitCode` |
| `RunResult.success` | factory | Empty success result |
| `RunResult.usage` | factory | Usage failure with message |
| `RunResult.content` | factory | Content failure with message |
| `RunResult.io` | factory | I/O failure with message |
| `RunResult.exitCode` | method | Delegate to `class.exitCode()` |

There is no formatting, sorting, JSON emission, or diagnostic aggregation in this file.

***

## Contract alignment

### Confirmed aligned with `docs/contracts/diagnostics.md`

| Contract rule | Implementation |
| :-- | :-- |
| Exit `0` success | `ExitCode.success = 0` |
| Exit `1` content / validation | `ExitCode.content_error = 1` |
| Exit `2` usage (`EUSAGE`) | `ExitCode.usage = 2` |
| Exit `3` I/O (`EIO`) | `ExitCode.io_error = 3` |
| Warnings alone do not force non-zero | Not implemented here — callers must not map warnings to `content_error` without errors; `diag.countErrors` is the content gate |

### Explicit non-ownership (by design)

- Content diagnostic codes and severity → `src/diag.zig`
- stderr text form of diagnostics → `diag.formatText` / `pipeline.printDiagnostics`
- Preferring exit `3` over `1` for pure I/O → caller policy in `main.zig` / `pipeline.Result.failure`
- `--help` exit `0` without scanning → CLI / main, not this module
- `--quiet` suppressing diagnostic text but not changing exit codes → CLI / main


### Relationship to `src/diag.zig`

| Concern | `diag.zig` | `diagnostic.zig` |
| :-- | :-- | :-- |
| Closed content codes | Yes (`Code` enum) | No |
| Severity | Yes | No |
| Process exit integers | No | Yes |
| Sort / format diagnostics | Yes | No |
| CLI result envelope | No | Yes (`RunResult`) |

The similar names are historical (Milestone 3 introduced `diagnostic.zig` for exit codes; later content diagnostics landed in `diag.zig`). They must not be treated as aliases.

***
