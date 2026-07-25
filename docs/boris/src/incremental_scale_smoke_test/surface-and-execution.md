---
title: "`src/incremental_scale_smoke_test.zig` surface and execution"
id: docs/boris/src/incremental_scale_smoke_test/surface-and-execution
parent: docs/boris/src/incremental_scale_smoke_test
status: draft
tags: [boris, zig, source-reference, surface, incremental_scale_smoke_test]
---

# `src/incremental_scale_smoke_test.zig` surface and execution

## Fixture topology

The generated content tree is fully synthetic and constructed in-memory, then written to disk by `writeSite`. It is deterministic for a given run (no random content). Key constants embedded at the top of the file:

| Constant | Value | Meaning |
| --- | --- | --- |
| `trunk_count` | 20 | Number of Trunk documents |
| `satellites_per_trunk` | 9 | Satellites per Trunk |
| `page_count` | 200 | `trunk_count * (1 + satellites_per_trunk)` |
| `edited_cohort_count` | 10 | `1 + satellites_per_trunk` — pages expected dirty after one edit |
| `changed_trunk` | 7 | Index (0-based) of the edited Trunk |
| `changed_satellite` | 3 | Index of the edited Satellite within that Trunk |

Each Trunk page (`trunks/trunk-NN.md`) contains a wikilink to its own Satellite cohort's page `satellites/trunk-NN/page-00.md` (with the special case that `trunk-07` links to `satellites/trunk-07/page-03.md` — the satellite that will be edited). Each Satellite page declares `parent: trunks/trunk-NN`. The layout is a minimal `<html><body>&#123;&#123;content&#125;&#125;</body></html>` template.

The edit (`reviseSatellite`) overwrites `satellites/trunk-07/page-03.md` with a revised title and body. The test then asserts that the incremental build re-renders exactly `edited_cohort_count` pages.

## Allocator and I/O patterns

`std.testing.allocator` (the leak-checking GPA) is used for all allocations in the test body and helpers. `std.testing.io` is used throughout, consistent with the Boris test convention. All allocations in `WorkDir`, `writeSite`, `reviseSatellite`, and the comparison helpers use explicit `gpa.free` or `defer gpa.free` — there are no arena-local leaks within the test scaffolding itself.

The two calls to `compileSite` that supply multiple jobs use `compile.compileHtmlSite` with `jobs = 4`. The actual thread spawning and `ParallelContext` machinery are exercised inside `compile.compileHtmlSite`; the test itself is single-threaded at the coordinator level.
