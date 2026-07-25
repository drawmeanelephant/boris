---
title: "`src/watch.zig` overview"
id: docs/boris/src/watch
status: draft
tags: [boris, zig, source-reference, watch]
---

# `src/watch.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/watch/surface-and-execution|Surface and execution]]
* [[docs/boris/src/watch/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/watch/review-state|Review state]]

## Executive summary

`src/watch.zig` is the watch-mode subsystem for Boris. It provides all the machinery needed to observe a content tree for filesystem changes, debounce and coalesce those changes into a deduplicated key set, select which build targets are affected, and trigger an incremental rebuild — while surviving transient OS and content errors without terminating the watcher session.

The file is simultaneously a production module and a self-contained unit-test suite. The production types (`Watcher`, `PollingWatcher`, `WatchCoordinator`) are compiled into the Boris binary when the user invokes `boris watch`. The test types (`FakeWatcher`) are used only by the inline tests; they do not appear in the production binary's call graph unless explicitly linked.

The system boundary this file protects is the feedback loop between filesystem events and rebuild invocations. The key correctness properties it must maintain are: (1) no spurious rebuilds from Boris's own output files; (2) no missed rebuilds due to path spelling variations; (3) no infinite rebuild loops from a file that changes faster than a rebuild completes; (4) continued watch session operation when content or layout errors occur; and (5) correct fan-out of layout changes to only the affected subset of multi-target builds.

Execution is entirely single-threaded and synchronous. There is no thread pool, no OS-native filesystem event API (inotify, kqueue, FSEvents), and no async task model. The polling loop in `WatchCoordinator.run` sleeps, polls, debounces, and rebuilds in a sequential cycle on the calling thread. `should_shutdown_global` is an `std.atomic.Value(bool)` written only from POSIX signal handlers and read only from the main loop thread — a correct but deliberately narrow use of atomics.

The unit tests in this file are self-contained: they use `FakeWatcher` to inject events and inspect `WatchCoordinator.pending_changes` directly without ever performing a real filesystem scan or a real compile step. This gives high confidence in the path-filtering, normalization, deduplication, and fan-out logic, but provides no coverage of `PollingWatcher.poll`'s filesystem interaction, the actual rebuild pipeline, the signal handler, or behavior under concurrent modification.

What the tests do not prove: correct behavior when `scanFiles` encounters symlink loops, when mtime granularity is too coarse to detect a within-same-second modification, when the OS delivers `rename` as a sequence of delete+create, when two targets share the same `output_dir`, or when `normalizePath` receives an absolute path on Windows (backslash conversion is tested but absolute-path handling is not exercised).

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with inline unit tests |
| Conceptual domain | Watch mode: filesystem change detection, debounce, event routing, rebuild dispatch |
| Build or test root | Part of the main `boris` binary; also compiled as the root for the watch unit-test step (exact step name not confirmed from `build.zig`, but the inline `test` blocks are exercised by `zig build test` or equivalent) |
| Production runtime dependency | Yes — imported by `src/main.zig` for the `watch` subcommand |
| Expected execution command | `zig build test` (unit tests); `boris watch --input content --output dist` (production) |
| Main collaborators | `src/compile.zig` (rebuild entry points), `src/cli.zig` (Options, TargetSpec container), `src/target.zig` (TargetSpec, `declaredLayoutPaths`) |
| Documentation depth warranted | High — the debounce, fan-out, and path-filtering logic have non-obvious edge cases that are tested but not self-documenting from the API surface alone |

***

## Role in the Boris architecture

`src/watch.zig` is a production dependency of `src/main.zig`. When the user runs `boris watch`, `main.zig` constructs a `PollingWatcher`, wraps it in the `Watcher` interface, passes both to `WatchCoordinator.init`, and calls `WatchCoordinator.run`. The coordinator owns the event loop for the lifetime of that process invocation.

This file has no dependency on `src/apex.zig` or ApexMarkdown. It does not perform Markdown parsing, HTML rendering, or any content transformation. Its only contact with compilation is through two call sites in `triggerRebuild`: `compile.compileHtmlSite` (single-target path) and `compile.compileHtmlSiteMulti` (multi-target path). It treats those calls as black boxes and catches errors by name using `isRecoverableBuildError`.

The `FakeWatcher` type is architecturally a test double for any `Watcher`-interface implementation. It is defined in this file alongside production code; there is no separate test-doubles package. It is not compiled conditionally — it is always present in the module. Whether it is included in the production binary depends on whether the linker dead-strips unreferenced symbols; this is not confirmed from the available build configuration.

The normal test suite (`src/fixtures_test.zig`, `src/hardening_test.zig`, etc.) tests the compile and pipeline layers. `src/watch.zig`'s inline tests specifically exercise the watch coordinator and its helpers in isolation from the filesystem and compile pipeline.

`src/watch.zig` has no relationship to `src/apex_hostile_test.zig`. The two files occupy different subsystems and share no imports.

***
