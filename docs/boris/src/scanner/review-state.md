---
title: "`src/scanner.zig` review state"
id: docs/boris/src/scanner/review-state
parent: docs/boris/src/scanner
status: draft
tags: [boris, zig, source-reference, review-state, scanner]
---

# `src/scanner.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Coverage gaps and residual uncertainty

| Gap | Category |
| :-- | :-- |
| `scanDir` entry point not separately tested | Untested delegation |
| Defense-in-depth `stat` symlink check (second layer) has no isolated test | Structurally checked, not directly demonstrated |
| `SymlinkCycle` from a live directory cycle has no corresponding test | Contract-only (code present, no live fixture) |
| OOM / allocation failure paths in `registerPage` and `visited_dirs.append` | Not tested |
| `.assets`-suffix directory skip has no dedicated test | Structurally present, not directly demonstrated |
| `includes` file defense-in-depth guard in `registerPage` is not independently exercised | Structurally present, not directly demonstrated |
| `identitySeen` linear search behavior at large `visited_dirs` scale | Not tested |
| Behavior on a symlink-capable Windows host that does not deny creation | Uncertain (skipped entirely) |
| `entry.path` lifetime invalidation across `walker.next()` calls | Not tested in isolation; relies on code structure |


***

## Potential follow-up work

> This section describes observations and possible improvements. It is not a patch proposal and does not modify any repository file.

- Add a test that independently exercises the defense-in-depth `stat`-based symlink check by using a walker test double or fixture that reports a symlink as `.file`.
- Add a test for `error.SymlinkCycle` using a bind-mount or a pre-constructed fixture inode collision (or a walker mock that emits the same inode twice).
- Add a test covering the `.assets` directory skip, confirming that files inside a `page.assets/` subtree are never registered.
- Consider OOM injection tests for `visited_dirs.append` and `registerPage` allocation paths to verify error propagation does not leak walker state.
- The `identitySeen` linear search is O(n) in directory count; for content trees with large numbers of distinct directories, a hash set would be preferable. No profiling exists in the repository to justify the change at this time.
- `scanDir` has no dedicated test. Either delete it (it is a thin wrapper with a fixed default) or add a test that observes its Markdown-default behavior distinctly from `scanDirFormat`.
