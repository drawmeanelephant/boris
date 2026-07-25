---
title: "`tools/migration-lab/archaeology.zig` review state"
id: docs/tools/migration-lab/archaeology/review-state
parent: docs/tools/migration-lab/archaeology
status: draft
tags: [boris, zig, tools, review-state, migration-lab, archaeology]
---

# `tools/migration-lab/archaeology.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Stale-output cleanup contract:** The WordPress mode README documents that re-running wipes lab-owned content. Whether Astro mode does the same is undocumented. Observed evidence: no explicit documentation or test. Why it matters: a developer who re-runs after adding files may see stale reports. Smallest follow-up: add a line to the Astro mode section of the README. Need: likely.
- **`archaeology.run` function contract:** The full `run` function body was not available in the examined sources. A dedicated dossier section on the `run` function's sort key, arena strategy, and cleanup behavior would close the largest gap in this document. Need: confirmed gap.
- **Symlink policy documentation:** Whether the Astro walk follows, skips, or records symlinks is undocumented for this mode. The `themearchaeology.zig` peer explicitly documents its policy. Need: likely.
- **Schema stability contract:** `schemaVersion: 1` is present but there is no documented compatibility policy for consumers of `report.json`. Need: uncertain.


### Test follow-up

- **Symlink behavior:** No test exercises a symlink in the Astro scan root. Observed evidence: peer module has explicit symlink handling. Need: uncertain.
- **`--out` as subdirectory of `--root`:** The string-equality guard does not prevent this. A test exercising this case would either confirm the guard is sufficient or surface a containment gap. Need: likely.
- **Stale-output cleanup:** No test verifies that a second run removes artifacts from a first run that would no longer be generated. Need: uncertain.
- **Unreadable file during walk:** No test exercises a file that exists but cannot be read. Need: uncertain.
- **Allocation-failure paths:** No allocation-failure injection tests. Need: uncertain.
- **Cross-platform (Windows) path separators:** No evidence of Windows CI coverage. Need: uncertain.


### Implementation follow-up

- **Containment guard in `archaeology.run`:** The guard in `main.zig` catches `rootdir == outdir` by string equality but does not prevent `outdir` from being a subdirectory of `rootdir`. Moving the guard into `archaeology.run` (or adding a prefix check alongside the equality check) would close this gap without requiring caller discipline. Observed evidence: `themearchaeology.zig` has `refuseOutputInsideSource` which checks both equality and prefix; `archaeology.zig` equivalent is not confirmed. Need: likely.
- **Embedded-directive detection in walk:** `themearchaeology.zig` explicitly detects and drops source lines that look like LLM agent instructions. Whether `archaeology.zig` does the same is uncertain. If the Astro archaeology reports are consumed by LLM workflows (as documented in the Boris source-RAG use case), embedded instructions in source files could influence downstream behavior. Need: uncertain.
