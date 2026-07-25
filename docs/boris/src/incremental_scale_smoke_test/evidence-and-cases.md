---
title: "`src/incremental_scale_smoke_test.zig` evidence and cases"
id: docs/boris/src/incremental_scale_smoke_test/evidence-and-cases
parent: docs/boris/src/incremental_scale_smoke_test
status: draft
tags: [boris, zig, source-reference, evidence, incremental_scale_smoke_test]
---

# `src/incremental_scale_smoke_test.zig` evidence and cases

## Test harness construction

The module root is `src/incremental_scale_smoke_test.zig`. From `build.zig`:

```zig
const scale_smoke_mod = b.createModule(.{
    .root_source_file = b.path("src/incremental_scale_smoke_test.zig"),
    .target = target,
    .optimize = optimize,
});
linkApex(scale_smoke_mod, b, false);                     // real ApexMarkdown
scale_smoke_mod.addOptions("build_options", apex_opts);  // hostile_apex = false
const scale_smoke_tests = b.addTest(.{ .root_module = scale_smoke_mod });
const run_scale_smoke_tests = b.addRunArtifact(scale_smoke_tests);
run_scale_smoke_tests.setCwd(b.path("."));
const test_scale_smoke_step = b.step("test-scale-smoke", ...);
test_scale_smoke_step.dependOn(&run_scale_smoke_tests.step);
```

`scale_smoke_tests.step` is also added to `apex_needing`, so the build ensures the CMake-built ApexMarkdown archives are fresh before compiling. The `hostile_apex` build option is `false` — `apex.zig` will call the real C engine. There is no way for the hostile double to be accidentally used in this target.

The test file imports `compile.zig` directly via `@import("compile.zig")`. There is no indirection through a named import; it is a sibling source import. `std.Io` and `std.testing.io` are used throughout, consistent with the rest of the Boris test surface.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `"scale smoke: 200-page incremental edit is bounded and parallel-deterministic"` | `test` | End-to-end incremental HTML + parallel determinism | Synthetic 200-page content tree, one Satellite edit | Cold: 200 written; no-op: 0 written; revised: 10 written; byte-identical trees | `compileHtmlSite` incremental mode; `CompileStats.pages_written`; parallel rendering determinism |
| `WorkDir` (struct) | Helper | Creates/cleans a disposable per-run temp directory | `gpa`, `std.testing.io` | Randomized path under `test-output/`; cleaned on `defer` | `std.Io` directory + file API |
| `WorkDir.create` | Method | Allocates work directory path with 4-byte random suffix | `gpa`, `io` | Unique directory created; `rel` string owned by `gpa` | `io.random`, `createDirPath`, `allocPrint` |
| `WorkDir.cleanup` | Method | Deletes tree and frees path | — | Directory gone; no leak | `deleteTree`, `gpa.free` |
| `WorkDir.join` | Method | Allocates a joined path `{rel}/{child}` | `child: []const u8` | Caller-owned allocation | `allocPrint` |
| `WorkDir.writeFile` | Method | Writes data to a relative path, creating parent dirs | `rel_path`, `data` | File exists on disk | `createDirPath`, `Io.Dir.writeFile` |
| `WorkDir.readFile` | Method | Reads file into caller-supplied allocator | `rel_path`, `allocator` | Caller-owned bytes | `openFile`, `reader.allocRemaining` |
| `writeSite` | fn | Generates the full 200-page content tree on disk | `work`, `root` | 200 `.md` files + layout under `{root}/` | File writing; frontmatter format |
| `reviseSatellite` | fn | Overwrites the single designated Satellite with new title/body | `work`, `root` | One file updated | File writing |
| `compileSite` | fn | Calls `compile.compileHtmlSite` with `incremental = true` | `io`, `gpa`, paths, `jobs` | `CompileStats` | `compileHtmlSite` |
| `publishedTreesByteIdentical` | fn | Asserts two dist directories contain the same files with identical bytes | `io`, `gpa`, `a_root`, `b_root` | No assertion failure | File traversal + `expectEqualSlices` |
| `collectPublishedPaths` | fn | Recursively collects file paths under a root, skipping `.boris-cache/` | `io`, `gpa`, `arena`, `root_path` | Populated `paths` list | Dir walk; `.boris-cache/` exclusion |
| `readFromDir` | fn | Reads a file from an already-open `Io.Dir` | `io`, `gpa`, `dir`, `path` | Caller-owned bytes | `openFile`, `allocRemaining` |

## Walkthrough of the single test

### Phase 1 — Sequential cold build

**Setup:** `writeSite(&work, "sequential")` generates the full 200-page tree. `compileSite(io, gpa, ..., 1)` is called once.

**Assertion:** `cold.pages_written == 200`. This is a directly demonstrated check against `CompileStats.pages_written`. It confirms that the first invocation of `compileHtmlSite` with `incremental = true` on an empty `dist/` writes every page.

**Contract exercised:** Cold-start incremental build must treat all pages as dirty when no cache manifest exists.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Does not confirm that the cache manifest was actually written to disk (only that 200 pages were written). The no-op phase below provides indirect confirmation.

***

### Phase 2 — Sequential no-op build

**Setup:** `compileSite` is called a second time on the unchanged `dist/` and `content/`.

**Assertion:** `unchanged.pages_written == 0`. This directly demonstrates that after a successful cold build, no pages are dirty on the next invocation with identical inputs.

**Contract exercised:** The content-addressed fingerprinting + output-digest check must skip all 200 pages when no source, layout, or graph material has changed.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Does not test manifest corruption, partial manifest, or version mismatch. Those are covered by unit tests in `compile.zig`.

***

### Phase 3 — Sequential incremental edit

**Setup:** Before revision, the test reads and captures:

- `sequential/dist/trunks/trunk-07.html` (the Trunk that wikilinks to the edited Satellite — `parent_before`)
- `sequential/dist/satellites/trunk-07/page-03.html` (the directly edited page — `changed_before`)
- `sequential/dist/trunks/trunk-08.html` (an unrelated Trunk — `unrelated_before`)

Then `reviseSatellite(&work, "sequential")` overwrites `satellites/trunk-07/page-03.md` with a new title ("Satellite 07-03 revised") and new body ("Revised scale-smoke body 07-03.").

`compileSite` is called again.

**Assertions:**

- `revised.pages_written == edited_cohort_count` (`== 10`): exactly the edited Trunk and its full Satellite cohort were re-rendered.
- `parent_after != parent_before`: the Trunk HTML changed (it was re-rendered and reflects the updated wikilink target title).
- `changed_after != changed_before`: the edited Satellite HTML changed.
- `unrelated_after == unrelated_before` (byte-for-byte via `expectEqualSlices`): trunk-08 and its cohort were not touched.
- `parent_after` contains the string `"Satellite 07-03 revised"`.
- `changed_after` contains the string `"Revised scale-smoke body 07-03."`.

**Contract exercised:** The reverse-dependency expansion (`expandDirtySet`) must propagate a dirty Satellite upward to its Trunk and sibling Satellites, but must not propagate to unrelated Trunks. The wikilink title interpolation into the parent must reflect the new title.

**Evidence strength:** Directly demonstrated for the 10-page cohort and the `trunk-08` control page. The file comment notes the cohort boundary is "conservative" — the test proves the current behavior, not a formal minimum dirty set.

**Residual gap:** Only one Satellite cohort is tested. Trunk-level edits, multi-Trunk dependency chains, include-based dependency propagation, and wikilink-via-include paths are not covered here (they are covered in `compile.zig` unit tests and `F8.3` tests).

***

### Phase 4 — Parallel cold build

**Setup:** `writeSite(&work, "parallel")` generates a separate, identical content tree. `compileSite(io, gpa, ..., 4)` is called (four workers).

**Assertions:**

- `parallel_cold.pages_written == 200`: cold build with four workers writes all pages.
- `parallel_unchanged.pages_written == 0`: no-op pass with four workers.
- (After `reviseSatellite`) `parallel_revised.pages_written == edited_cohort_count`.
- `parallel_repeat.pages_written == 0`: incremental pass after re-render with no further change writes nothing.

**Contract exercised:** The parallel rendering path (`ParallelContext`, `parallelWorker`) produces the same output counts as the sequential path.

**Evidence strength:** Directly demonstrated for counts.

***

### Phase 5 — Byte-identity assertion

**Setup:** `publishedTreesByteIdentical(io, gpa, sequential_dist, parallel_dist)` compares the two dist trees.

**Internal steps:**

1. `collectPublishedPaths` walks each tree, skipping `.boris-cache/` entries.
2. Both path lists are sorted lexicographically.
3. The path lists must be equal in length; corresponding paths must match.
4. For every pair, the file bytes must be equal via `expectEqualSlices`.

**Contract exercised:** Parallel rendering with `jobs = 4` must produce a byte-for-byte identical published HTML tree to sequential rendering with `jobs = 1`, for the same content at the same edited state. This is the primary determinism proof for the parallel path.

**Note:** `.boris-cache/` files (the incremental manifest and heading-harvest cache) are intentionally excluded from the comparison. The test does not assert that these cache files are byte-identical between runs — they may record different intermediate state.

**Evidence strength:** Directly demonstrated for all published HTML files in both trees. The cache files are not compared; whether they are structurally equivalent is not tested here.

**Residual gap:** The comparison happens after the parallel tree has been brought to the same edited state as the sequential tree. It does not test a cold parallel build against a cold sequential build — only the post-edit state is compared. Whether the parallel cold output would also be identical is not directly asserted (though it is structurally implied by the same content inputs).

## Control flow

```text
test "scale smoke: ..."
    │
    ├─ WorkDir.create                  (random temp dir under test-output/)
    │
    ├─ writeSite → "sequential"        (20 Trunks × 10 pages = 200 .md files)
    │
    ├─ compileSite(jobs=1)             → cold: pages_written == 200
    │       └─ compile.compileHtmlSite (incremental=true, jobs=1)
    │               └─ real ApexMarkdown via apex.zig
    │
    ├─ compileSite(jobs=1)             → unchanged: pages_written == 0
    │
    ├─ readFile × 3                    (capture parent_before, changed_before, unrelated_before)
    │
    ├─ reviseSatellite                 (overwrite satellites/trunk-07/page-03.md)
    │
    ├─ compileSite(jobs=1)             → revised: pages_written == 10
    │       └─ compile.compileHtmlSite
    │               ├─ fingerprint all 200 pages
    │               ├─ mark 1 page dirty (changed source)
    │               ├─ expandDirtySet  (reverse-dep walk → marks 10 pages dirty)
    │               └─ render 10 dirty pages
    │
    ├─ readFile × 3                    (parent_after, changed_after, unrelated_after)
    ├─ expect parent changed
    ├─ expect changed changed
    ├─ expect unrelated unchanged (byte-identical)
    ├─ expect "Satellite 07-03 revised" in parent_after
    ├─ expect "Revised scale-smoke body 07-03." in changed_after
    │
    ├─ writeSite → "parallel"          (identical 200-page tree, separate dir)
    │
    ├─ compileSite(jobs=4)             → parallel_cold: pages_written == 200
    ├─ compileSite(jobs=4)             → parallel_unchanged: pages_written == 0
    ├─ reviseSatellite (parallel)
    ├─ compileSite(jobs=4)             → parallel_revised: pages_written == 10
    ├─ compileSite(jobs=4)             → parallel_repeat: pages_written == 0
    │
    ├─ publishedTreesByteIdentical(sequential_dist, parallel_dist)
    │       ├─ collectPublishedPaths (skip .boris-cache/)
    │       ├─ sort both path lists
    │       ├─ expectEqual(len, len)
    │       └─ for each pair: expectEqualSlices(a_bytes, b_bytes)
    │
    └─ WorkDir.cleanup                 (deleteTree, gpa.free)
```

## What the test does not cover

Per `test/scale-smoke/README.md` (directly):

- No performance benchmark or elapsed-time threshold
- Does not assert the narrowest-possible dirty set (the cohort boundary is conservative)
- Does not stress arbitrary graph shapes
- Does not replace unit tests or hostile ABI gates
- Does not test the production CLI invocation path
- Does not assert `.boris-cache/` file contents or format
- Does not cover Textile input, include directives, wikilinks, or graph chrome in the scale fixture
