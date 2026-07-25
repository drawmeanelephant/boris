---
title: "`tools/migration-lab/wordpress_theme.zig` review state"
id: docs/tools/migration-lab/wordpress_theme/review-state
parent: docs/tools/migration-lab/wordpress_theme
status: draft
tags: [boris, zig, tools, review-state, migration-lab, wordpress_theme]
---

# `tools/migration-lab/wordpress_theme.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Symlink policy:** The README's safety rule table does not include a symlink policy for `wordpress-theme` mode (unlike `asset-filename` mode which explicitly rejects symlinks). Documenting the current behavior (undefined) or adding a stated policy would reduce ambiguity. Observed: no symlink handling in `walkTree`. Importance: moderate. Need: confirmed gap.
- **Evidence boundary for `style.css` scanning:** The README notes that `style.css` provenance fields are scanned, but the precise list of scanned keys (`Theme Name`, `Theme URI`, `Author`, `Version`, `Template`) is only in the source. A brief contract note would help. Need: uncertain (low priority).
- **Partial output on failure:** The README does not warn that a failed mid-run leaves partial output in `--out`. Adding a note would help users know to re-run cleanly. Need: likely.


### Test follow-up

- **Cross-platform byte identity:** No test verifies that `inventory.json` output is byte-identical on macOS vs. Linux. The sort is unconditional, but filesystem encoding differences could affect path strings. Need: uncertain.
- **Hostile filename bytes in source tree:** A fixture with PHP files named with control characters, null bytes, or embedded quotes would verify that `appendJson` escaping handles them safely in output. Need: likely (security hygiene).
- **Symlink in source tree:** A fixture with a symlink pointing outside `--root` would document current behavior (follow or skip). Need: confirmed gap.
- **Very large PHP file:** A fixture or size-limit test would establish OOM behavior. Need: uncertain.
- **Partial output on mid-run I/O failure:** An injected I/O failure after the first `writeBytes` would verify that the caller can detect partial output. Need: uncertain.
- **`refuseOutputInsideSource` trailing slash and symlink normalization:** The current test does not cover `./theme/` vs `./theme` or symlink-equivalent paths. Need: likely.


### Implementation follow-up

- **Symlink guard in `walkTree`:** Other migration-lab modes (e.g., `asset-filename`) explicitly reject symlinks. Adding `if (entry.kind == .sym_link) continue;` or an explicit error would align with the stated safety posture. Observed: not present. Need: likely.
- **File size limit in `readFileAlloc`:** A configurable or hardcoded cap (e.g., 1 MB) on PHP file size before scanning would bound memory usage. Observed: `.unlimited`. Need: uncertain.
- **Stale output cleanup:** Rerunning against the same `--out` leaves extraneous files from prior runs if the set of emitted files changes between versions. An explicit wipe of `--out` at run start (as noted in the WordPress WXR module's `toolVersion` comment) would prevent stale file accumulation. Need: uncertain.
