---
title: "`src/pathutil.zig` review state"
id: docs/boris/src/pathutil/review-state
parent: docs/boris/src/pathutil
status: draft
tags: [boris, zig, source-reference, review-state, pathutil]
---

# `src/pathutil.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

> **This section contains suggestions only. No changes to repository files are proposed here.**

1. **Confirm whether `pathutil.zig` has any active importers.** A full `grep -r 'pathutil' src/` across the working tree would resolve the uncertainty left by the code-search result. If there are no active importers, the file is a dead shim and can be removed in a single mechanical change.

2. **If importers exist, migrate them to `identity.zig`.** The migration is mechanical: replace `@import("pathutil.zig")` with `@import("identity.zig")` at each call site and rename any uses of the aliased historical names (`isMarkdownFile`, `entityIdFromSource`, `idFromSourcePath`) to their canonical counterparts.

3. **Add a compile-time deprecation warning.** Until the shim is removed, a `@compileLog` or a prominent `@deprecated` doc comment on each aliased symbol would surface the migration signal at the point of use rather than only at the module level.

4. **Verify `AGENTS.md` task-routing table.** The table lists `pathutil` alongside `graph`, `diag`, and `json_out` as the preferred edit target for compiler IR and graph tasks. If `pathutil.zig` is being retired in favor of `identity.zig`, the table entry should be updated to name `identity` instead.
