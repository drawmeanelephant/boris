---
title: "`src/watch.zig` review state"
id: docs/boris/src/watch/review-state
parent: docs/boris/src/watch
status: draft
tags: [boris, zig, source-reference, review-state, watch]
---

# `src/watch.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Known gaps and limitations

The following behaviors are not mechanically enforced or tested by the current code:

- **Windows signal shutdown**: No signal handler is installed on Windows. `should_shutdown_global` is never set to `true` by any code path in `watch.zig` on Windows; the loop would run until the process is killed externally.
- **Coarse mtime granularity**: `FileStamp` stores `mtime_ns` but the underlying filesystem may only provide 1- or 2-second precision. Writes within the same timestamp tick that change only content (not size) would not be detected.
- **`scanFiles` symlink loops**: `scanFiles` skips `sym_link` kind entries in the walk but does not follow or detect dangling symlinks to directories that the walker might recurse into if the OS returns them as `directory` entries. Whether `walkSelectively` handles this is not confirmed from the available evidence.
- **`PollingWatcher.poll` error handling**: Transient scan errors for individual roots cause `continue` (keep the previous snapshot for that root), but this silently discards all new-file detections for that root during the failed poll cycle. A file created during a transient-error poll will not be reported until the next successful scan.
- **`rename` events**: `EventKind` includes `rename`, and `FakeWatcher` can inject it, but `processEvents` treats all event kinds identically (only the path matters). A `rename` event does not produce a paired delete+create. Whether this is intentional (leaving rename handling to the compile pipeline) is not documented.
- **`normalizePath` on absolute paths (Windows)**: `normalizePath` converts `\\` to `/` but does not handle `C:\`-style absolute paths. This is not tested.
- **Concurrent access to `FakeWatcher`**: The doc comment explicitly states it is not safe for concurrent push/poll. There is no enforcement mechanism.

***

## Potential follow-up work

*This section records observations for future consideration. No code changes are proposed here.*

- The `should_shutdown_global` module-level `pub var` couples any importer to the module's shutdown state. A coordinator-local atomic (or a closure-captured pointer) would remove the implicit global dependency and allow multiple coordinators (e.g., in tests) without interference.
- `isRecoverableBuildError` lists `error.MultiTargetCompilationFailed` in a comment inside `triggerRebuild` but not in the function body itself. The two sites that check for it (`run` initial build path, `triggerRebuild`) duplicate the special-case, which could diverge.
- The debounce loop reads `pending_changes.count()` to detect stabilization but does not account for the case where events arrive and cancel each other (e.g., create followed by delete of the same file). Both events would be collapsed to one key, making the count appear stable while a real change occurred.
- `FakeWatcher` is defined in the production module. Relocating it to a test-only file would make the production module's public API smaller and its intent clearer.
- `scanFiles` uses `@intCast` on `stat.mtime.nanoseconds` to convert to `i128`. No overflow check is present; the behavior for negative or out-of-range values from unusual FS implementations is not addressed.
