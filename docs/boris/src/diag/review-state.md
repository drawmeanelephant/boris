---
title: "`src/diag.zig` review state"
id: docs/boris/src/diag/review-state
parent: docs/boris/src/diag
status: draft
tags: [boris, zig, source-reference, review-state, diag]
---

# `src/diag.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Identified gaps and potential follow-up work

The following are observations about coverage and design gaps in the current state of the file. They are documentation of known limits, not defect reports or prescriptive change requests.

**Test coverage gaps:**

- Four `Code` variants (`ERELATIONMISSING`, `ERELATIONSELF`, `ERELATIONDUPLICATE`, `EASSET`) are absent from the name test. Adding them would complete the contract alignment check.
- No test exercises `formatText` for any of its three branches, the remediation append path, or the null-column-to-1 default.
- No test exercises `countErrors`.
- No test exercises sort stability, or any sort key beyond path and line.
- No test exercises sort behavior when `line == null` (verifying maxInt placement).

**Design observations:**

- `sortDiagnostics` uses `std.mem.sort`, which is unstable in Zig's standard library. Two diagnostics equal on all five keys may appear in either order. For deterministic output, a stable sort or a sixth tie-breaking key (e.g., original insertion index) would be needed. Whether any consumer requires full determinism for equal diagnostics is not determined here.
- The `formatText` remediation allocation pattern (allocate with `defer free`, then re-allocate in the outer call) is correct for general-purpose allocators but relies on `defer` executing before the outer `allocPrint`. This is guaranteed by Zig's defer semantics, but the pattern is subtle enough to warrant a comment.
- `textName()` as a pure alias for `jsonName()` provides no isolation if text and JSON severity representations ever diverge.
- The `source_path == ""` default versus contract's `null` JSON value is a caller contract not enforced anywhere in this file. A conformance note or a dedicated helper that maps `""` to JSON null during serialization would reduce the risk of callers emitting invalid JSON.
