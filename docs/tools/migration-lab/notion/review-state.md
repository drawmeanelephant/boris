---
title: "`tools/migration-lab/notion.zig` review state"
id: docs/tools/migration-lab/notion/review-state
parent: docs/tools/migration-lab/notion
status: draft
tags: [boris, zig, tools, review-state, migration-lab, notion]
---

# `tools/migration-lab/notion.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **`mediamanifest.json` schema:** The per-entry fields are referenced in tests by substring (`status copied`) but no schema document or field list is formally specified. Documenting the schema would reduce uncertainty for consumers. (Need: likely; confirmation: uncertain.)
- **Stale-output behavior:** The README and module header do not explicitly document whether a re-run into the same `--out` cleans up content from the prior run. Documenting this (or aligning with WordPress's explicit stale-cleanup behavior) would reduce consumer confusion. (Need: likely.)
- **Symlink policy:** The Notion mode's behavior on symlinked files or directories within the export tree is not documented. (Need: uncertain.)


### Test follow-up

- **Stale-output cleanup test for notion mode:** WordPress has a dedicated test (`test "wordpress re-run into same out dir wipes stale content"`). A parallel notion test would provide direct evidence. (Observed: absent; importance: moderate — partial stale output could mislead a human reviewer.)
- **Symlink escape test:** A test analogous to `test "wordpress media symlink escape is rejected"` for the notion export tree would close the symlink safety gap. (Observed: absent; importance: moderate.)
- **Allocation-failure coverage:** `std.testing.allocator` with a failing allocator is not used in the integration test; allocation-failure paths are not directly tested. (Need: uncertain priority.)
- **Path traversal end-to-end test:** An adversarial export fixture with `..`-containing link targets and percent-encoded traversal sequences would directly demonstrate the path-safety chain. (Observed: not evidenced for notion mode; importance: high for trust.)
- **Cross-platform determinism:** No Windows CI evidence; byte-identical repeated-run test only demonstrates single-host determinism. (Need: uncertain — depends on CI scope.)


### Implementation follow-up

- **Output-root containment check:** The `--out != --export` guard in `main.zig` uses string equality and does not check prefix containment. If `--out` is a subdirectory of `--export` or vice versa, the tool could write into the export tree. A prefix-containment check (analogous to `refuseOutputInsideSource` in `themearchaeology.zig`) would close this gap. (Observed gap: structurally evident from `main.zig` guard code; need: confirmed.)
- **Cleanup on failure:** If `run` returns an error after partial output, the partial output directory is not cleaned up. A consistent partial-output cleanup strategy (or documented absence of one) would align with the WordPress stale-cleanup behavior. (Observed: uncertain; need: uncertain.)

***
