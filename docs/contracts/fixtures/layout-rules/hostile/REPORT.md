# Layout selection hostile audit report (PR #50 + path hardening)

**Date:** 2026-07-15  
**Branch:** `grok/layout-selection-hostile`  
**Scope:** Hostile audit of merged PR #50 layout selection, plus optional
layout-path lexical hardening.  
**Harness:** `src/layout_select_hostile_test.zig` · fixtures under this directory  
**Gates:** `zig build test-layout-hostile`, `zig build test`, `./scripts/release-gate.sh`

## Method

1. Checked out fresh `origin/main` (PR #50 merge).
2. Added Zig-only hostile fixtures + integration harness.
3. Probed pure selector logic, CLI parse, target validation, and HTML compile.
4. Landed optional hardening: `layout_select.validateLayoutPath` on all layout
   path entry points (`--html-layout`, `--target-layout`, `--layout-rule`,
   `--theme`, library compile / target validate).

## Gate results

| Gate | Result |
|------|--------|
| `zig build test-layout-hostile` | **PASS** |
| `zig build test` | **PASS** |
| `./scripts/release-gate.sh` | **PASS** (incl. 4c2 + traversal path checks) |

## Scenario matrix

| ID | Scenario | Result | Classification |
|----|----------|--------|----------------|
| H1 | Exact id > glob > role > fallback | Pass | Non-issue |
| H2 | Equal-specificity glob ambiguity | Pass | Non-issue |
| H3 | Rule-order permutation determinism | Pass | Non-issue |
| H4 | Fallback chain | Pass | Non-issue |
| H5a | Mixed theme roots | Pass | Non-issue |
| H5b | Missing layout file | Pass (fail closed) | Non-issue |
| H5c | Traversal / absolute / `\` layout paths | Pass (`InvalidLayoutPath` / CLI `InvalidValue`) | **Hardened** (was limitation) |
| H5d | Invalid selectors / duplicates / IR conflict | Pass | Non-issue |
| H6 | Multi-target isolation | Pass | Non-issue |
| H7 | Incremental rebuild after selected layout change | Pass | Non-issue |
| H8 | Stale cleanup | Pass | Non-issue |
| H9 | Full vs incremental byte-for-byte | Pass | Non-issue |
| H10 | Repeated-run determinism | Pass | Non-issue |

## Findings

### Confirmed defects

**None** for layout-selection correctness on PR #50.

### Hardening delivered

**Layout path lexical gate** (`layout_select.validateLayoutPath`):

- Rejects absolute paths, Windows drive letters, backslashes, empty / `.` /
  `..` segments, trailing separators.
- Wired at: CLI parse (`--html-layout`, `--target-layout`, `--layout-rule`,
  `--theme`), `target.validateTargets`, `compile.compileHtmlSite` (before
  open), and `compilePagesInner` (defense in depth).
- Maps to usage exit **2** (`InvalidValue` at CLI; `InvalidLayoutPath` in
  library / `mapHtmlError`).

This closes the prior observation that `..` layout paths only failed at
load/mixed-root rather than uniformly at configuration time.

### Remaining non-blockers

1. **Cache manifests are incremental-only** — expected; not a layout defect.
2. **Orphan HTML scrub is strongest on full rebuild** — documented compile
   behavior; H8 covers both paths.

## Reproduce

```bash
zig build test-layout-hostile
zig build test
./scripts/release-gate.sh
```

## Summary

PR #50 layout selection is contract-correct under hostile pressure. Optional
path hardening is implemented and covered by unit, hostile, and release-gate
checks. Ready for review/merge.
