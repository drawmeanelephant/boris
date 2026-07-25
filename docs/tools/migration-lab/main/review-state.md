---
title: "`tools/migration-lab/main.zig` review state"
id: docs/tools/migration-lab/main/review-state
parent: docs/tools/migration-lab/main
status: draft
tags: [boris, zig, tools, review-state, migration-lab, main]
---

# `tools/migration-lab/main.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

1. **Root `build.zig` step name**: The exact `zig build <step>` name for `boris-migration-lab` at the repo root is undocumented in the evidence. **Observed evidence:** `build.zig` not inspected. **Why it matters:** operators trying to build from repo root need the correct step name. **Plausible follow-up:** read root `build.zig` and document the step. **Confidence:** confirmed gap.
2. **Exit code contract**: Exit codes 0/2/3 are documented in comments but not tested. **Observed evidence:** `ExitCode` enum; comment in `printUsage`. **Why it matters:** callers scripting the tool need reliable exit codes. **Plausible follow-up:** add a sentence to the README and test at least the usage-error exit code. **Confidence:** confirmed gap.
3. **Per-mode schema documentation**: Most manifests lack a format identifier or have identifiers without a written schema contract. **Observed evidence:** `routemap.json` has `schemaVersion: 1`; most others do not. **Why it matters:** consumers of machine output need a stable contract. **Plausible follow-up:** document fields and versioning policy for each manifest in README or a `schemas/` directory. **Confidence:** likely needed.
4. **`--out` containment vs equality semantics**: The current guard only checks string equality. **Observed evidence:** `main` source. **Why it matters:** operators may inadvertently supply overlapping paths that are not string-equal. **Plausible follow-up:** document the limitation in README. **Confidence:** confirmed gap.

### Test follow-up

1. **Two-run byte comparison for non-astro modes**: Only `astro` and `wordpress-theme` have visible two-run determinism tests. WordPress, Instagram, Obsidian, Notion, Filed, Starlight, asset-filename, link-audit, frontmatter-review lack visible two-run tests in `main.zig`. **Observed evidence:** test block. **Why it matters:** output stability for all modes is a developer expectation. **Plausible follow-up:** add byte-comparison tests for representative fixture runs of each mode. **Confidence:** confirmed gap.
2. **`--out` equals `--root` CLI guard test**: The guard is structurally present in `main` but no test explicitly exercises the "output inside input" rejection path. **Observed evidence:** `main` source. **Why it matters:** accidental overwrite risk. **Plausible follow-up:** add a test that supplies `--root . --out .` and asserts `error.OutputInsideSource` or `ExitCode.usage`. **Confidence:** confirmed gap.
3. **Instagram allocator leak**: The `instagram` module is excluded from `refAllDecls` due to a known leak. **Observed evidence:** comment in test block. **Why it matters:** memory leaks in long-running or repeatedly invoked tools degrade process hygiene. **Plausible follow-up:** investigate leak, fix, and re-enable. **Confidence:** confirmed issue, scope uncertain.
4. **Stale-output cleanup behavior test**: No test verifies that files from a previous run that no longer exist in a new run are handled correctly (or documents that they are intentionally not cleaned). **Observed evidence:** absence of cleanup logic. **Why it matters:** incremental runs may leave stale artifacts. **Plausible follow-up:** document the policy; add a test if cleanup is desired. **Confidence:** confirmed gap.
5. **Allocation failure coverage**: No `FailingAllocator` tests observed. **Observed evidence:** absence. **Why it matters:** failure paths under OOM are untested. **Confidence:** uncertain whether this is intentional.

### Implementation follow-up

1. **`refuseOutputInsideSource` universality**: The function is present in `wordpresstheme.zig` and called in `starlight.run`, but it is uncertain whether every mode calls it. **Observed evidence:** structural analysis. **Why it matters:** modes that don't call it rely solely on the string-equality check in `main`. **Plausible follow-up:** audit all mode `run` functions; add the guard where absent. **Confidence:** likely gap.
2. **`--out` canonicalization**: The current guard uses `std.mem.eql(u8, input, opts.outdir)`. This does not catch `./migration-report` vs `migration-report` or symlink-aliased paths. **Observed evidence:** `main` source. **Why it matters:** edge cases could allow inadvertent output into the scanned tree. **Plausible follow-up:** consider `std.fs.realpath`-based comparison before calling `run`. **Confidence:** likely improvement; uncertain severity.
3. **Partial-output cleanup on error**: When `run` returns an error, the partially written output directory is left in place with no indication of which files are complete. **Observed evidence:** absence of cleanup logic. **Why it matters:** a developer re-running after a failure may observe a mix of old and new output. **Plausible follow-up:** document the behavior; optionally write a `run-incomplete` sentinel file. **Confidence:** uncertain priority.

***
