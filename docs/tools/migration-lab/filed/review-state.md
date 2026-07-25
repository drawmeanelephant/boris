---
title: "`tools/migration-lab/filed.zig` review state"
id: docs/tools/migration-lab/filed/review-state
parent: docs/tools/migration-lab/filed
status: draft
tags: [boris, zig, tools, review-state, migration-lab, filed]
---

# `tools/migration-lab/filed.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Schema documentation for `provenancemanifest.json` and `report.json`:** No tracked schema file exists. A machine-readable schema (JSON Schema or equivalent) would allow downstream consumers to validate output without reading the source. *Observed evidence:* format IDs and field lists are in source; no separate schema file found. *Why it matters:* consumers of migration output (review workflows, LLM notebooks) must currently infer the schema from source or generated examples. *Plausible follow-up:* add a `docs/contracts/filed-fyi-provenance.schema.json`. *Confidence: likely.*
- **`isSafeParentId` contract documentation:** The function is a local mirror of Boris entity-id rules; the exact divergence (if any) from the product validator is undocumented. *Why it matters:* a future product-schema change could silently invalidate previously accepted parent values. *Plausible follow-up:* add a comment referencing the authoritative product rule and the deliberate non-import decision. *Confidence: likely.*


### Test follow-up

- **Stale-output cleanup test:** No test verifies that a re-run does not leave orphaned files from a prior run with a different fixture. *Observed evidence:* no `deleteTree` call in `run`; WordPress mode has an explicit stale-output test. *Why it matters:* a content author running migration twice could accumulate incorrect stale pages. *Plausible follow-up:* add a fixture test that runs `filed.run` twice with different cardinality (or different filenames) into the same output dir and verifies only current-run files are present — or explicitly document that the output dir should be fresh. *Confidence: confirmed need.*
- **Cardinality violation test:** No fixture with wrong collection counts exists. *Observed evidence:* `error.UnexpectedCollectionCardinality` is structural but untested. *Plausible follow-up:* add a fixture with 2 releases files and verify exit 3. *Confidence: confirmed need.*
- **Path traversal in collection entry names:** No test exercises an `entry.name` containing `/` or `..`. *Observed evidence:* structural check is not present in `collectCollection`. *Plausible follow-up:* add a test with a crafted directory structure (or mock Io) if the concern is confirmed to be reachable on target platforms. *Confidence: uncertain — OS-level guards may be sufficient.*
- **Control-character JSON escaping:** The `appendJson` function does not escape control characters in `[0x01..0x1f]` other than the five named ones. *Observed evidence:* source of `appendJson` in the pack. *Why it matters:* a source file containing a null byte or raw control character in frontmatter would produce non-compliant JSON output. *Plausible follow-up:* add a test with a control character in a frontmatter value. *Confidence: likely.*


### Implementation follow-up

- **Stale-output deletion:** `run` could delete the output directory before writing, or walk the output tree and remove files not in the current record set, consistent with the pattern used by other lab modes (WordPress mode does an explicit stale wipe). *Observed evidence:* WordPress `run` uses `Io.Dir.cwd.deleteTree` before writing. *Plausible follow-up:* add a `deleteTree(outdir)` at the start of `run`, or add a note to `RunOptions` that the caller should ensure a clean output dir. *Confidence: likely.*
- **Output-inside-source guard: symlink safety:** The prefix check is a string comparison, not a realpath comparison. A symlink-based bypass is theoretically possible. *Observed evidence:* string comparison in source. *Plausible follow-up:* document the limitation explicitly in `RunOptions`. *Confidence: uncertain — depends on deployment threat model.*

***
