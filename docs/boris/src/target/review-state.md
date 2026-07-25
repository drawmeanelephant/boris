---
title: "`src/target.zig` review state"
id: docs/boris/src/target/review-state
parent: docs/boris/src/target
status: draft
tags: [boris, zig, source-reference, review-state, target]
---

# `src/target.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Gaps and untested paths

- **`rejectSymlinkAlongPath` positive case:** No inline test creates a filesystem symlink and asserts `error.TargetOutputSymlink`. The symlink-rejection code path is exercised structurally (correct logic is readable) but is not directly demonstrated by an automated test in this file. (`src/theme.zig` has a symlink test using a tmpdir, but that is a different rejection point.)
- **`rejectMixedThemeRoots` directly:** Only called indirectly through `validateTargets` (via the layout-rule path). No standalone test of `rejectMixedThemeRoots` exists in this file.
- **`printTargetConfigLines` and `declaredLayoutPaths`:** No inline tests.
- **Case-insensitive path comparison:** `caseInsensitiveFs()` returns `true` on macOS/Windows at compile time. The correctness of the case-insensitive branch is only exercised when tests are run on those platforms.
- **`resolveNormalized` edge cases on Windows:** Drive-letter normalization and UNC paths are handled by `std.fs.path.resolve`; the behavior of the "trim and re-dupe" branch for trailing slashes on those paths is not tested inline.
- **Layout rule validation in `validateTargets`:** The `validateLayoutPath` call on rule paths and the `rejectMixedThemeRoots` call are not directly exercised by any `validateTargets` sub-case in the inline test (all test specs use empty `layout_rules`). Their correctness for non-empty rule tables depends on the tests in `src/layout_select.zig` and `src/theme.zig`.

## Potential follow-up work

> This section records possible improvements. It does not constitute approved work and must not be acted on without explicit user request.

- Add a tmpdir-based inline test for `rejectSymlinkAlongPath` to directly demonstrate the `error.TargetOutputSymlink` path, analogous to the symlink test in `src/theme.zig`.
- Add a direct inline test for `rejectMixedThemeRoots` with a managed-theme layout and a legacy layout in the same rule table.
- Add inline tests for `validateTargets` with non-empty `layout_rules` to cover the `validateLayoutPath`-on-rule and `rejectMixedThemeRoots` paths end-to-end.
- Add a test for `printTargetConfigLines` output format (currently no coverage).
- Consider extracting the TOCTOU-narrowing second `rejectSymlinkAlongPath` call into a documented pre-open helper that callers are required to invoke, so the calling convention is enforced rather than advisory.
- Evaluate whether the O(n²) duplicate-name scan and the O(n²) overlap scan need to be bounded or replaced with a hash set for large target counts (currently not a practical concern; worth noting for future large-configuration support).
