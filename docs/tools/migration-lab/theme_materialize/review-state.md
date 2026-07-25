---
title: "`tools/migration-lab/theme_materialize.zig` review state"
id: docs/tools/migration-lab/theme_materialize/review-state
parent: docs/tools/migration-lab/theme_materialize
status: draft
tags: [boris, zig, tools, review-state, migration-lab, theme_materialize]
---

# `tools/migration-lab/theme_materialize.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Ledger schema contract**: `adaptationledger.json` field names, types, and valid decision/category values are consumed by this module but documented only partially in `themearchaeology.zig`. A tracked schema definition (e.g., in `docs/contracts/`) would allow this module to reference a version contract rather than implicit coupling. Observed: consumed fields; need: formal schema doc. Priority: likely.
- **Empty SHA bypass**: the behavior where an empty `sha256` field in the ledger skips verification is not documented in the README or module comments. A human editing the ledger might not know this. Priority: likely.
- **Stale output behavior**: the README and module do not document that previous output files are not cleaned up on re-run. Priority: likely.


### Test follow-up

- **Stale output detection**: verify that a re-run with a reduced ledger does not leave previously generated files in `outdir`. Observed: no cleanup code; gap matters for correct theme draft state. Priority: confirmed gap.
- **Empty SHA field bypass test**: add a test case where a ledger entry has an empty `sha256` field; verify that the copy proceeds. Or add a test that verifies the bypass is intentional. Priority: likely.
- **Windows absolute path**: test that `isSafeRelativePath` rejects `C:\evil.css`. Priority: uncertain (platform availability).
- **Markdown injection in report**: test that a `sourcepath` containing `|` or Markdown metacharacters does not corrupt `materialize-manifest.json` (already escaped) vs. `MATERIALIZE-REPORT.md` (not escaped). Priority: likely.
- **Allocation failure path**: test behavior when `gpa` is an always-failing allocator. Priority: uncertain.
- **Symlink in source tree**: confirm whether `Io.Dir.openFile` follows symlinks and whether that is the intended behavior. Priority: confirmed gap based on contrast with `wordpress.zig`.


### Implementation follow-up

- **Stale output cleanup**: consider deleting or clearing `outdir` at the start of `run`, or documenting explicitly that callers must clean up between runs. Observed: no cleanup; callers may retain stale files. Smallest follow-up: document the behavior. Priority: likely.
- **Windows drive-letter path safety**: extend `isSafeRelativePath` to reject paths matching `[A-Za-z]:\`. Observed: current check misses this. Priority: uncertain.
- **Symlink rejection in source reads**: add an explicit symlink check before `readFile(source, sourcepath)`, mirroring `wordpress.zig` behavior. Observed: gap vs. sibling module. Priority: likely.
- **Size limit on source file reads**: add a guard against reading extremely large files into the arena. Observed: no limit; very large theme assets could exhaust memory. Priority: uncertain.

***
