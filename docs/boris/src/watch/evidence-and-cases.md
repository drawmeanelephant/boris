---
title: "`src/watch.zig` evidence and cases"
id: docs/boris/src/watch/evidence-and-cases
parent: docs/boris/src/watch
status: draft
tags: [boris, zig, source-reference, evidence, watch]
---

# `src/watch.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `normalizePath helper` | Unit test | Verifies backslash conversion, `./` stripping, trailing `/` removal, `.` collapse, `..` resolution | Various raw path strings | Exact expected normalized strings via `expectEqualStrings` | Equivalent spellings of the same path produce identical keys |
| `hasPathPrefix boundary` | Unit test | Verifies prefix matching is path-boundary aware, not substring | Various path/prefix pairs | Boolean true/false via `expect` | `dist` does not match `distribution/x.md` |
| `hasPathComponent` | Unit test | Verifies component-aware matching for `.boris-cache` and `.boris` | Paths with matching and non-matching components | Boolean true/false | `about-boris.md` is not filtered by `.boris` component rule |
| `isIgnored helper` | Unit test | Verifies the combined output/staging/cache/tmp filter | Output, staging, cache, tmp, and legitimate content paths | Boolean true/false | Sibling stage tree ignored; author paths with `.boris-stage` text kept; `distribution/` not confused with `dist` |
| `translateToKey helper` | Unit test | Verifies content-root stripping on path-boundary only | Paths with exact match, sibling prefix, trailing slash on root | Expected key strings | `content2/a.md` not stripped when root is `content` |
| `FakeWatcher and Coordinator Event Coalescing` | Integration test | Verifies that duplicate events produce a single pending key and that two distinct keys are preserved | 3 events: two for same path, one for a new path | `pending_changes.count() == 2` with correct keys | Event deduplication in `processEvents` |
| `processEvents ignores output and staging paths` | Integration test | Verifies output dir, normalized output path, and `.tmp` files are filtered; sibling prefix is not filtered | 5 events including `dist/`, `./dist/`, `.tmp`, real content, and `distribution/` | 2 pending changes: `real.md` and `distribution/not-output.md` | `isIgnored` with normalized paths; `distribution/` not confused with `dist` |
| `processEvents follow-up coalescing after drain` | Integration test | Verifies that after a manual drain simulating a rebuild, subsequent events re-queue correctly | Drain of pending map; then 2 new events including a previously-seen path | `pending_changes.count() == 2` | Map state after `clearRetainingCapacity` accepts new keys |
| `processEvents ignores multi-target output paths` | Integration test | Verifies `buildIgnoredOutputRoots` produces 4 entries for 2 targets and that both output dirs and both staging trees are filtered | 4 events: 2 output, 1 staging, 1 real content | `pending_changes.count() == 1` with `real.md` | Multi-target ignore root construction |
| `selectTargetsForRebuild layout vs content fan-out` | Unit test | Verifies content change fans to all targets; default layout change fans only to `prod`; stage layout fans only to `stage` | Two `TargetSpec` values with different layouts; three key scenarios | Subset lengths and target names | Core fan-out logic |
| `selectTargetsForRebuild normalizes layout path spellings` | Unit test | Verifies that `./layouts/main.html`, `layouts/./main.html`, `layouts/foo/../main.html` all match the correct target regardless of spelling | Three key scenarios with equivalent-spelling paths | Correct single-target subsets | Normalization applied before comparison in `selectTargetsForRebuild` |
| `processEvents does not ignore legitimate .boris-stage source paths` | Integration test | Verifies that only `dist.boris-stage` (the real staging tree) is ignored; author paths containing `.boris-stage` text are kept | 4 events: real staging, 3 author paths with the text | `pending_changes.count() == 3` with correct keys | `isSiblingStagePath` path-boundary check |
| `processEvents custom input root maps relative keys` | Integration test | Verifies that `./docs/src` as `input_dir` strips correctly; layout paths outside that root are kept whole | 5 events from `docs/src/`, `./docs/src/`, `docs/src/./`, `layouts/`, `dist/` | 4 pending changes with correct stripped and un-stripped keys | `translateToKey` with normalized root; ignore of output dir |
| `processEvents target-specific layout keys stay outside content strip` | Integration test | Verifies end-to-end: events processed and deduped, then `selectTargetsForRebuild` called with resulting keys to confirm correct fan-out | 5 events; content, two layout spellings, two output/staging paths | 3 pending changes; correct per-target subset from three subsequent `selectTargetsForRebuild` calls | Full path-to-fan-out pipeline |
| `watch recovery: pending drains and follow-up events still queue` | Integration test | Verifies that after a simulated build failure (pending drain without rebuild success), the coordinator continues accepting new events | Drain; then 2 new events | `pending_changes.count() == 2` | Session continuity after drain |
| `isRecoverableBuildError classification stays content-only` | Unit test | Directly tests the error classifier | Named error values | `expect(true)` for content errors; `expect(false)` for I/O errors | Recovery policy: hard I/O errors must not be suppressed |

***

## Behavioral walkthrough: key logic paths

### Event processing pipeline (`processEvents`)

```text
watcher.poll(&events)            ← appends Event{path, kind} values to the list
    ↓
for each event:
    normalizePath(event.path)    ← backslash→slash, strip ./,  resolve .., etc.
    ↓
    isIgnored(normalized, root)  ← check each ignored_output_root
    ↓ (not ignored)
    translateToKey(normalized, input_dir)  ← strip content_root prefix if present
    ↓
    pending_changes.getOrPut(key)  ← insert; free key if already present (dedup)
↓
events freed (paths freed per entry)
```

The event list is ephemeral: all `path` strings in it are freed in the `defer` block at the start of `processEvents`. The normalized path is also freed after use (`defer gpa.free(normalized)`). Only the translated key survives — owned by `pending_changes` — or is freed immediately if a duplicate.

### Rebuild dispatch (`triggerRebuild`)

```text
pending_changes.iterator()      ← move keys into paths ArrayList (no copy of values)
pending_changes.clearRetainingCapacity()
    ↓
sort paths alphabetically       ← deterministic log order
    ↓
if targets.len > 0:
    selectTargetsForRebuild(...)  ← layout-aware subset
    compile.compileHtmlSiteMulti(io, gpa, subset, opts)
else:
    compile.compileHtmlSite(io, gpa, opts)
    ↓ on error:
        isRecoverableBuildError(err) → return (keep watching)
        else → return err (terminate)
    ↓
paths freed (defer)
```

The key ownership transfer in `triggerRebuild` is: keys are moved from `pending_changes` into `paths`, the map is cleared with `clearRetainingCapacity` (retaining backing allocation), then `paths` items are freed in the `defer` block. This means keys are freed by `triggerRebuild`, not by the caller. A caller that has already freed keys (as done manually in some tests to simulate draining) must not pass those keys again.

### Debounce loop (`run`)

```text
loop:
    processEvents()
    ↓
    if pending_changes.count() > 0:
        coalesced := 0
        while coalesced < max_debounce_burst_ms:
            sleepMs(debounce_ms)
            coalesced += debounce_ms
            before := count()
            processEvents()
            if count() == before: break    ← stable; stop coalescing
        ↓
        triggerRebuild()
    else:
        sleepMs(idle_poll_ms)
    ↓
    check should_shutdown_global
```

FS changes that arrive during a rebuild are not observed during that rebuild — the loop does not poll during the compile step. They will be picked up on the next poll iteration after `triggerRebuild` returns.

***
