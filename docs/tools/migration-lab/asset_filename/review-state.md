---
title: "`tools/migration-lab/asset_filename.zig` review state"
id: docs/tools/migration-lab/asset_filename/review-state
parent: docs/tools/migration-lab/asset_filename
status: draft
tags: [boris, zig, tools, review-state, migration-lab, asset_filename]
---

# `tools/migration-lab/asset_filename.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **`rewrite_manifest.json` schema version field:** The manifest appears to lack a `schema_version` top-level field, unlike `asset_filename_manifest.json`. Adding and documenting it would align the format with the lab's other manifests. *Observed: schema_version absent in evidence. Why it matters: schema evolution will be untraceable without a version. Smallest follow-up: add `schema_version: 1` to the top-level object and document it in README. Need: likely.*
- **Collision fatality contract:** The README and safety rules do not clearly state whether a collision causes a failed run (exit 3) or a soft-rejected manifest entry (exit 0). The dossier could not determine this from available evidence. *Observed: `LabError.Collision` exists but usage is uncertain. Why it matters: callers need to know if a partial output can be trusted. Smallest follow-up: add one sentence to README safety rule 10. Need: confirmed.*
- **Fence-aware rewrite boundary:** The README states the Markdown rewrite is "fence-aware" but does not document the fence detection rules (triple-backtick only? tilde fences? indented code blocks?). *Observed: documented as fence-aware; implementation not reviewed. Why it matters: adversarial Markdown could bypass rewrite suppression. Smallest follow-up: add fence detection contract to README or inline comment. Need: likely.*


### Test follow-up

- **Stale-output behavior test:** No test verifies that a second run after removing a source asset does not leave orphaned output files. *Observed: no cleanup implementation; no test. Why it matters: operators may assume re-running produces a clean output. Smallest follow-up: add a fixture test that verifies `--out` contains only expected files. Need: likely.*
- **Allocation-failure coverage:** No test exercises OOM paths. *Observed: standard library allocator used without failure injection. Why it matters: large imports could exhaust memory silently. Smallest follow-up: add a failing-allocator wrapper test for `sanitizeSegment` and `urlDecodeAlloc`. Need: uncertain.*
- **Cross-platform sort stability:** The lexicographic sort relies on filesystem enumeration producing the same set of paths on each run. A test that explicitly constructs a known path order and verifies sort output would strengthen the determinism claim. *Observed: sort is in code but only tested on one platform. Need: uncertain.*
- **Symlink fixture commit verification:** Confirm whether a symlink is actually committed in `fixtures/hostile-asset-filenames/` and whether the test exercises real symlink detection. *Observed: README claims symlink present; git symlink commit is uncertain. Need: confirmed investigation needed.*


### Implementation follow-up

- **Atomic output publication:** Currently `writeFile` writes directly to the final destination. A write-to-temp-then-rename pattern would prevent partial writes from leaving a corrupt output if the process is interrupted. *Observed: direct `writeFile` calls in `writeBytes`. Why it matters: interrupted runs leave partial `--out` with no recovery path. Smallest follow-up: write to `{path}.tmp` then rename. Need: uncertain (single-run tool, partial output acceptable with re-run).*
- **Stale output cleanup:** Unlike the WordPress mode, this mode does not wipe `--out/content/` before re-running. Adding a pre-run `deleteTree` on `--out/content/` (with appropriate guard that `--out` does not overlap `--root`) would prevent orphaned assets from prior runs. *Observed: no cleanup in run. Why it matters: re-runs on shrunken inputs leave stale files. Smallest follow-up: add `deleteTree(out_dir/content)` before writing. Need: likely.*
- **Size guard on asset files:** `allocRemaining(.unlimited)` on asset files is unbounded. Adding a configurable or hardcoded size cap (e.g., 256 MiB) before reading would prevent OOM on adversarial inputs. *Observed: no size check in `readFileAlloc`. Need: uncertain.*

***
