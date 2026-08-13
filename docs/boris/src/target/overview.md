---
title: "`src/target.zig` overview"
id: docs/boris/src/target
status: draft
tags: [boris, zig, source-reference, target]
---

# `src/target.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/target/surface-and-execution|Surface and execution]]
* [[docs/boris/src/target/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/target/review-state|Review state]]

## Executive summary

`src/target.zig` is a production module that defines the complete lifecycle of a **build target** within the Boris compiler: from raw CLI input (`TargetSpec`) through path resolution, safety validation, and sorted output (`TargetPlan`). It is the authoritative place in the codebase where multi-target collision detection, workspace-escape prevention, symlink rejection, and layout-path integrity are enforced before any filesystem write is attempted.

The file serves two distinct but tightly coupled roles. First, it defines the data types (`TargetSpec`, `TargetPlan`) that the CLI parsing layer produces and that downstream rendering passes consume. Second, it houses `validateTargets`, the single validation gate that must succeed before any output directory is opened or any page is written. No build machinery is expected to open an output directory without a `TargetPlan` that has already passed this gate.

The module's protection perimeter is the workspace filesystem boundary: it prevents a misconfigured invocation from writing build outputs into the content source tree, into a layout directory, into a sibling workspace that shares a path prefix, or through a symlink that could escape the workspace. It also enforces that every target name satisfies a closed grammar, that names are unique, and that output directories do not nest or overlap — including case-insensitive comparison on Windows and macOS.

The file is linked directly into the production binary. It carries no build-step conditionality; it is always compiled. Its inline tests exercise `validateTargets` and the helper predicates with the standard `zig build test` test runner, using `std.testing.io` and `std.testing.allocator` rather than any hostile double or subprocess.

The confidence the inline tests provide is substantial: they cover the normal-success path, post-validation sort order, sibling-path disambiguation, every named error value (`DuplicateTargetName`, `InvalidTargetName`, `TargetOutputCollision`, `WorkspaceEscape`, `EmptyTargetDirectory`), content-root and layout-root collision, and input-order independence. What the tests do not cover: TOCTOU gaps between the validate call and the actual `openDir` call; the specific symlink-rejection path through `rejectSymlinkAlongPath` (no tmpdir fixture is created for that in-file); case-insensitive path comparison on a live case-insensitive filesystem (the `caseInsensitiveFs()` compile-time branch is exercised on whatever host the tests happen to run on); and the correctness of `rejectMixedThemeRoots` beyond the calls invoked implicitly by `validateTargets` (no direct test of that function appears in this file).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with inline unit tests |
| Conceptual domain | Build-target specification, path safety, output-directory validation |
| Build or test root | Imported by the Boris product binary; tests run under `zig build test` |
| Production runtime dependency | Yes — `validateTargets` is on the critical path before any output directory is opened |
| Expected execution command | `zig build test` (inline tests); production via normal `boris build` invocation |
| Main collaborators | `src/layout_select.zig` (`LayoutRule`, `collectDeclaredLayouts`, `validateLayoutPath`), `src/theme.zig` (`themeRootFromLayoutPath`), `std.process`, `std.fs.path`, `std.Io` |
| Documentation depth warranted | High — this is the sole path-safety gate before filesystem writes |

## Role in the Boris architecture

`src/target.zig` sits between the CLI argument parser and the per-target render pass. The CLI layer produces an `[]const TargetSpec` from parsed flags; `validateTargets` consumes that slice and returns an `[]const TargetPlan` whose `resolved_output_dir` fields are GPA-owned absolute, normalized paths. Downstream code (compilation, assemble, theme copy) operates on `TargetPlan` values and must not re-validate paths.

The file has no dependency on `src/render.zig` or the Oliver-backed rendering seam. It is entirely independent of Markdown rendering and is tested only by the standard `zig build test` step.

The module is not a test-only artifact. It is compiled into every Boris binary. The inline tests (the `test` blocks at the bottom of the file) are compiled and run by the Zig test runner but do not ship in release builds.

`src/layout_select.zig` is the principal collaborator: `target.zig` calls `layout_select.collectDeclaredLayouts` and `layout_select.validateLayoutPath` during `validateTargets`, and imports `layout_select.LayoutRule` as the type of the rule table field on both `TargetSpec` and `TargetPlan`. `src/theme.zig` is called via `rejectMixedThemeRoots`, which uses `theme_mod.themeRootFromLayoutPath` to ensure all layout paths within a target resolve to the same managed-theme root (or are all legacy).
