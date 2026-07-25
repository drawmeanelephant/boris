---
title: "`tools/migration-lab/obsidian.zig` review state"
id: docs/tools/migration-lab/obsidian/review-state
parent: docs/tools/migration-lab/obsidian
status: draft
tags: [boris, zig, tools, review-state, migration-lab, obsidian]
---

# `tools/migration-lab/obsidian.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Obsidian schema contract**: The `report.json` top-level field order is implied by determinism tests but not documented as a formal contract (unlike WordPress mode which has explicit schema notes in the README). A schema note analogous to the WordPress schema comment in the README would clarify stability expectations. (Evidence: README has explicit schema notes for WordPress/Notion/Obsidian; the Obsidian note is brief. Need: confirmed.)
- **Ten-rule resolution chain**: The ordered wiki-link resolution rules (rules 1–11 in README) should be cross-referenced against the `rewriteBody` implementation to confirm parity. (Evidence: README lists 11 rules; source implements them. Need: likely, minor gap.)
- **`attachmentsmanifest.json` field documentation**: The manifest's JSON schema (field names, types, `referenced`, `copied` semantics) is not documented anywhere outside the source. (Evidence: format only visible in source. Need: confirmed.)


### Test follow-up

- **Hostile-obsidian fixture**: A `fixtures/hostile-obsidian` fixture analogous to `fixtures/hostile-asset-filenames` and `fixtures/hostile-starlight` would exercise vault filenames containing `../`, absolute paths, very long names, Unicode, control characters, and shell-special characters. (Evidence: no such fixture exists; other modes have hostile fixtures. Need: confirmed gap.)
- **Symlink fixture**: A vault with symlinked files or directories would verify the claimed symlink-skip behavior mechanically. (Evidence: README states symlinks not followed; no test. Need: confirmed.)
- **Attachment copy failure**: A fixture that makes an attachment unreadable (e.g., by providing a vault where an attachment is missing) would directly test the `copied: false` / `human_review` path. (Evidence: path structurally present in code; not triggered by mini-obsidian fixture. Need: likely.)
- **Output-inside-source prefix check**: A test invoking `run` with `outdir` as a subdirectory of `vaultdir` (not equal but nested) would expose the prefix-containment gap. (Evidence: only equality is checked. Need: confirmed gap, but policy question whether to fix in `main.zig` or `run`.)
- **Allocation-failure coverage**: Tests under a failing allocator (e.g., `std.testing.FailingAllocator`) are absent for `obsidian.zig`. (Evidence: no such test. Need: uncertain priority.)


### Implementation follow-up

- **Prefix-containment check for `--out` vs `--vault`**: `main.zig` currently checks only string equality. If `outdir` is a prefix-path of `vaultdir` or vice versa, the walk could recurse into generated output or overwrite vault files. A `refuseOutputInsideSource`-style check (as implemented in `themearchaeology.zig`) would close this gap. (Evidence: `refuseOutputInsideSource` exists in `themearchaeology.zig` but is not used in the obsidian dispatch path. Need: likely — other modes have the same gap; the hostile-asset-filenames mode does use a stricter form.)
- **Path traversal guard for vault-relative output paths**: Before writing a page or attachment under `outdir`, a containment check (e.g., resolving the canonical output path and confirming it is under `outdir`) would prevent a maliciously named vault file from writing outside the output root. (Evidence: no such guard visible. Need: confirmed gap; severity depends on whether tool is ever run on untrusted vaults.)
