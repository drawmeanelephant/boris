---
title: "`src/llms.zig` review state"
id: docs/boris/src/llms/review-state
parent: docs/boris/src/llms
status: draft
tags: [boris, zig, source-reference, review-state, llms]
---

# `src/llms.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Correctness properties and gaps

**Directly demonstrated by test:**

- `summary` strips frontmatter and returns the first body paragraph.
- `summary` falls back to the `fallback` argument when no body text follows headings.

**Structurally checked by code:**

- `run` returns `error.AbsolutePath` for absolute `content_root` or `out_path`.
- `renderPage` will not infinitely loop on a cycle because the `visited` guard prevents re-entry.
- Compilation failure causes early return; `publish` is only called if `result.compile.ok`.
- `errdefer result.deinit()` in `run` ensures the arena is freed even if rendering or publishing fails.

**Contract-only (not mechanically enforced in this file):**

- The graph passed to `render` is expected to be a validated, cycle-free forest. `llms.zig` does not call `graph.validate` itself; it relies on `pipeline.compile` having done so and having set `result.compile.ok = false` on validation errors.
- URL root-relativity is stated as intentional in a comment but not verified by a test.

**Uncertain:**

- Behavior of `ensureParent` when `createDirPath` encounters an already-existing directory — assumed safe but not confirmed from the `std.Io` source visible here.
- Whether `readFileAlloc` with `.unlimited` size cap can allocate unreasonably large buffers for unexpectedly large source files; no upper bound is enforced.
- Whether `Io.Dir.cwd().rename` is atomic on non-POSIX platforms; the publish sequence assumes POSIX rename semantics for the anti-tear property.

**Not covered by any test in this file:**

- `appendInline` escaping behavior for all five special characters and control-character normalization.
- `appendUrl` output format.
- `renderPage` tree structure, indentation levels, and visited-guard behavior.
- `render` two-pass fallback for orphaned nodes.
- `publish` staged rename and rollback behavior.
- `run` end-to-end integration against a fixture content tree.

***

## Potential follow-up work

The following observations do not constitute confirmed defects. They are surfaced as candidates for future work based on coverage gaps and structural analysis.

- **Integration test for `run`:** The module has no end-to-end test against a fixture content tree. A minimal fixture (2–3 pages, one trunk/satellite pair) would cover the pipeline-to-publish path and serve as a regression baseline.
- **`appendInline` unit test:** The escaping function handles five special characters and three control characters; none are independently tested. A table-driven test would close this gap.
- **`summary` edge cases:** No test for documents without frontmatter delimiters or multi-line paragraphs; exactly-240-byte input and UTF-8-boundary truncation are now covered by inline tests.
- **File size cap in `readFileAlloc`:** The `.unlimited` cap in `allocRemaining` means a pathologically large source file will allocate proportionally. A configurable or hard cap would make memory usage predictable.
- **`publish` atomicity caveat:** The rename-based staging sequence is not atomic on all platforms (e.g., Windows prior to NTFS transaction support). A documented `// POSIX only` comment or a platform check would make this explicit.
- **`renderPage` recursion depth:** v0.1 enforces max depth 2 at graph validation time, but `renderPage` does not independently enforce this. A future graph role that relaxes the depth constraint would silently allow deeper recursion without a corresponding guard here.
