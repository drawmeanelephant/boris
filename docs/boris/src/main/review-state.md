---
title: "`src/main.zig` review state"
id: docs/boris/src/main/review-state
parent: docs/boris/src/main
status: draft
tags: [boris, zig, source-reference, review-state, cli, entrypoint]
---

# `src/main.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Notable invariants and coverage gaps

**Invariants confirmed by tests:**

- All four `ExitCode` integer values are stable and exactly `{0,1,2,3}` (directly demonstrated).
- Valid fixture content at `docs/contracts/fixtures/valid/content` produces exit 0 from the IR pipeline (directly demonstrated).
- The duplicate-ID fixture produces exit 1 (directly demonstrated).
- A non-existent content root produces exit 3 from both IR and HTML modes (directly demonstrated).
- Seven specific HTML error values each map to `.usage` or `.io_error` as documented (directly demonstrated for listed errors; the `else` arm mapping unknown errors to `.io_error` is structurally covered but not explicitly enumerated).
- Multi-target collision, workspace escape, and content overlap all produce exit 2 (directly demonstrated with real tmpDir calls).

**Coverage gaps:**

- `runIntelligence` (`check` and `impact` commands) is not exercised with real fixture content; only tested via `SilentRunner` which returns `.success` unconditionally.
- `renderAnalysisJson` and `renderAnalysisHuman` are not directly tested.
- `runContext` and `runLlms` are not directly tested from `main.zig`; they may be covered in their own module test files (not inspected here).
- The watch loop and `add_layout_root` deduplication logic in `runHtml` have no test coverage in this file.
- `mapHtmlError`'s `else` arm (covering I/O errors other than the explicitly listed ones) is tested only structurally: the arm exists and maps to `.io_error`, but no test explicitly injects an unlisted error value.
- The `--textile` input format is not exercised through the HTML pipeline from `main.zig`.
- Incremental HTML mode and multi-job rendering (`jobs > 1`) are not tested here.
- The `quiet` flag's effect on stderr output is not directly asserted (all integration tests pass `quiet: true`; that `std.debug.print` calls are guarded by `!opts.quiet` is structurally visible but not tested with `quiet: false` in integration context).

***
