---
title: "`src/layout_select_hostile_test.zig` review state"
id: docs/boris/src/layout_select_hostile_test/review-state
parent: docs/boris/src/layout_select_hostile_test
status: draft
tags: [boris, zig, source-reference, review-state, layout_select_hostile_test]
---

# `src/layout_select_hostile_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

The following gaps were identified during analysis. They are observations only; no code changes are proposed here.

- **Exact error type for missing layout file.** H5-missing asserts only `std.meta.isError(result)`. Pinning the error to a specific value (e.g., `error.LayoutFileNotFound` or `error.FileNotFound`) would make regression detection more precise.
- **Traversal via symlink not covered.** `validateLayoutPath` is lexical. A symlink under the theme directory that escapes the workspace root would not be caught. An integration test using a symlink fixture would close this gap if the operating environment supports symlinks.
- **Three-theme-root mix.** H5-mixed tests only two-root mixing. A three-way mix is not covered.
- **Error diagnostic message content.** No test asserts the text or structured fields of diagnostic messages emitted on `AmbiguousGlob`, `MixedThemeRoots`, or `InvalidLayoutPath`. Adding assertions on diagnostic output would harden the user-facing error surface.
- **Partial output cleanup on failure.** H2-html checks that certain files do not exist after a compile error, but does not assert that the dist directory itself is absent or empty. If the compiler wrote some pages before encountering the ambiguous page, those would be left behind. Whether this is intended behavior is not documented.
- **Cache format version key assertion scope.** H10 spot-checks `"boris-cache-v2-layout-rules"` as a substring. A more structured assertion on the manifest schema would catch silent version key renames.
