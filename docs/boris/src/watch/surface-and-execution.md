---
title: "`src/watch.zig` surface and execution"
id: docs/boris/src/watch/surface-and-execution
parent: docs/boris/src/watch
status: draft
tags: [boris, zig, source-reference, surface, watch]
---

# `src/watch.zig` surface and execution

## Architectural concepts

### Watcher interface

`Watcher` is a hand-rolled vtable interface: a `ptr: *anyopaque` plus a `vtable: *const VTable` containing function pointers for `deinit` and `poll`. This is the standard Zig pattern for runtime polymorphism without virtual dispatch overhead from a heap-allocated interface object. Both `FakeWatcher` and `PollingWatcher` expose a `.watcher()` method that constructs a `Watcher` value pointing at the concrete instance. The coordinator holds only the `Watcher` value and never knows the concrete type.

The `poll` function appends `Event` values (each owning their `path` slice via the provided allocator) to a caller-supplied `std.ArrayList(Event)`. The coordinator is responsible for freeing all paths in the event list after processing. Ownership is explicit and one-directional: the watcher allocates paths; the caller frees them.

### FileStamp and change detection

`FileStamp` combines `mtime_ns: i128` and `size: u64`. The module comment explains the rationale: mtime alone is insufficient on filesystems with coarse-granularity timestamps or mtime-preserving writes. Using both fields together reduces false negatives. However, the stamp is compared with `!=` — no tolerance window — so a filesystem with 1-second mtime granularity (FAT32, some network mounts) could produce missed detections for within-second writes. This is noted as a known limitation by the use of `i128` for nanoseconds even though the underlying FS may not provide nanosecond precision.

### Debounce and coalescing

Three timing constants govern the loop:
- `debounce_ms = 100`: after the first change is observed, wait this long before triggering a rebuild.
- `max_debounce_burst_ms = 2000`: hard cap on total coalescing time, preventing a continuously-changing file from blocking rebuilds indefinitely (issue #17 in comments).
- `idle_poll_ms = 500`: sleep duration when no changes are pending, kept larger than `debounce_ms` to reduce polling cost on large trees.

The debounce logic inside `WatchCoordinator.run` checks whether `pending_changes.count()` grew between two consecutive `processEvents` calls. If it did not grow, the burst ends and a rebuild is triggered. If it did grow, another `debounce_ms` sleep is added, up to the `max_debounce_burst_ms` ceiling.

### Path normalization and filtering

`normalizePath` converts backslashes to forward slashes, strips leading `./`, collapses empty segments and `.` components, and resolves `..` by popping the preceding segment (with a guard against popping a leading `..`). The result is an allocator-owned slice. This normalization is applied to both event paths and layout declaration paths before any comparison, ensuring that `./layouts/main.html`, `layouts/./main.html`, and `layouts/main.html` all compare equal.

`isIgnored` uses three separate checks: `hasPathPrefix` for the output directory (path-boundary aware, not substring), `isSiblingStagePath` for the atomic staging tree (`{output}.boris-stage`), and direct checks for `.tmp` extensions and `.boris-cache` / `.boris` component names. The staging-tree check is path-boundary only, so an author file like `content/notes.boris-stage/readme.md` is not ignored.

`shouldSkipScanDir` prevents `PollingWatcher` from recursing into `.git`, `node_modules`, `.zig-cache`, `zig-cache`, `zig-out`, `.boris-cache`, and `.boris`. The comment clarifies that `.boris-stage` is filtered at the `isIgnored` stage (by path-prefix) rather than here (by basename), because a legitimate content directory whose name contains `.boris-stage` should still be scanned.

### Fan-out: `selectTargetsForRebuild`

When multi-target builds are active, layout changes should rebuild only the targets that declare that layout. `selectTargetsForRebuild` implements this by:
1. Calling `target_mod.declaredLayoutPaths` for each target to get all layout paths it uses (default fallback plus any per-rule overrides).
2. Normalizing all layout paths with `normalizePath`.
3. For each changed key, checking whether it matches any normalized layout path.
4. If a key matches no layout path, it is assumed to be a content or include file and `rebuild_all` is set, causing the function to return all targets.
5. If all keys match layout paths, only the targets that declared those layouts are returned.
6. If the computed subset is empty (no target declares any of the changed layouts — which would be unusual), the function falls back to returning all targets.

The function allocates a GPA-owned slice of `TargetSpec` copies (shallow copies; string fields still borrow the original argv storage). The caller is responsible for freeing only the outer slice.

### Error recovery

`isRecoverableBuildError` classifies `error.ParseFailed`, `error.ComponentFailed`, `error.TextileFailed`, `error.InputFormatMismatch`, `error.LayoutMissingMarker`, and `error.LayoutDuplicateMarker` as recoverable. When a rebuild returns one of these errors, the coordinator prints a diagnostic and returns without propagating the error, keeping the watch loop alive. All other errors propagate, terminating the loop. `error.MultiTargetCompilationFailed` is treated as recoverable in `triggerRebuild` (it is caught explicitly alongside the `isRecoverableBuildError` result) but is not listed inside `isRecoverableBuildError` itself.

### Signal handling

On non-Windows targets, `WatchCoordinator.run` installs `handleSigInt` as the handler for both `SIGINT` and `SIGTERM`. The handler writes `true` to `should_shutdown_global` with `.unordered` ordering. The main loop reads it with `.unordered` ordering. This is sufficient for the single-flag shutdown pattern but does not provide sequentially-consistent visibility guarantees; whether `.unordered` is adequate here depends on the platform's memory model. The `should_shutdown_global` variable is a module-level `pub var`, making it accessible to any code that imports `watch.zig`. On Windows, no signal handler is installed and `should_shutdown_global` is never set to `true` by the module itself; external code would need to set it to shut down the loop on Windows.

***

## Ownership and allocation inventory

| Resource | Allocated by | Freed by | Notes |
| :-- | :-- | :-- | :-- |
| `FakeWatcher.queued_events` paths | `pushEvent` via `allocator.dupe` | `FakeWatcher.deinit` or consumed by `poll` | `poll` drains and frees them |
| `Event.path` from `FakeWatcher.poll` | `FakeWatcher.poll` via `allocator.dupe` | Caller (`processEvents` defer block) |  |
| `Event.path` from `PollingWatcher.poll` | `PollingWatcher.poll` via `allocator.dupe` | Caller (`processEvents` defer block) |  |
| `PollingWatcher.roots` items | `addRoot` via `allocator.dupe` | `PollingWatcher.deinit` |  |
| `PollingWatcher.file_map` keys | `scanFiles` via `std.fs.path.join` | `PollingWatcher.deinit` or replaced each poll cycle | Old map keys freed at end of each `poll`; new map keys promoted to self |
| `WatchCoordinator.pending_changes` keys | `processEvents` via `translateToKey` → `allocator.dupe` | `WatchCoordinator.deinit` (residual) or `triggerRebuild` (moved to paths, then freed) | Keys are never freed twice; duplication check in `getOrPut` frees the new key if already present |
| `WatchCoordinator.ignored_output_roots` items | `buildIgnoredOutputRoots` via `normalizePath` / `allocPrint` | `WatchCoordinator.deinit` |  |
| `selectTargetsForRebuild` layout_lists | Inside `selectTargetsForRebuild` via `gpa` | Freed by the function before return (defer) |  |
| `selectTargetsForRebuild` result slice | `gpa.dupe` | Caller | Outer slice only; `TargetSpec` string fields borrow original argv |


***
