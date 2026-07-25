---
title: "`src/diagnostic.zig` review state"
id: docs/boris/src/diagnostic/review-state
parent: docs/boris/src/diagnostic
status: draft
tags: [boris, zig, source-reference, review-state, diagnostic]
---

# `src/diagnostic.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Identified gaps and potential follow-up work

Documentation of known limits only; not change requests.

**Test coverage gaps:**

- `RunResult.content` / `.io` / `.success` message fields are not asserted (only `usage` message is).
- No test that a default `RunResult{}` has `class == .none` and `message == null`.
- No integration test in this file that `ExitCode.int()` is what `std.process.exit` would receive (that lives in main-level tests if present).

**Design / clarity observations:**

- Naming collision risk with `diag.zig` for new contributors; the header comment mitigates this but the pair of names remains easy to confuse in imports (`import("diagnostic.zig")` vs `import("diag.zig")`).
- `FailureClass` and pipeline `FailureKind` are parallel enums with overlapping names (`content`, `io`, `none`) but different scopes (`usage` only on `FailureClass`). A shared type or an explicit conversion helper is not present in this file.
- `RunResult.message` ownership is documentation-only; nothing prevents a caller from passing a temporary stack buffer and later reading a dangling slice. This is consistent with other Boris “caller retains” patterns but is not mechanically enforced.
- The module does not re-export or reference `diag.Code.EUSAGE` / `EIO`; the conceptual link to those codes is contract-level only.

**What this file does not prove:**

- That every product code path that should exit `2` actually uses `ExitCode.usage`.
- That content failures with zero `error` diagnostics never exit `1` (pipeline/`main` responsibility).
- Thread-safety or reentrancy — not claimed; the types are plain values with no shared mutable state in this file.
