---
title: "`tools/migration-lab/wordpress.zig` review state"
id: docs/tools/migration-lab/wordpress/review-state
parent: docs/tools/migration-lab/wordpress
status: draft
tags: [boris, zig, tools, review-state, migration-lab, wordpress]
---

# `tools/migration-lab/wordpress.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

1. **Schema contract for `report.json` and `mediamanifest.json`.**
*Observed:* Schema version 3 is embedded but no external schema document or field-level contract exists. *Why it matters:* Tooling that consumes `report.json` has no stable contract to validate against. *Smallest follow-up:* Add a `docs/contracts/wordpress-migration-lab-report.schema.json` or equivalent Markdown contract. *Confidence:* Likely needed.
2. **Document the stale-output wipe scope and silent-failure behavior.**
*Observed:* `deleteTree` failures are silently swallowed. *Why it matters:* Authors re-running the tool may not notice stale content mixed into output. *Smallest follow-up:* Document the risk in `README.md` and optionally log a warning. *Confidence:* Confirmed gap.
3. **Document the Markdown fence safety limitation.**
*Observed:* No documentation of ````` injection risk in preserved HTML bodies. *Why it matters:* Authors who pipe output through automated processors may encounter unexpected behavior. *Smallest follow-up:* Add a note in `README.md`. *Confidence:* Likely.

### Test follow-up

1. **Repeated-run byte-identity test.**
*Observed:* No test compares two independent runs on the same input for byte-identical output. *Why it matters:* Determinism is claimed by design; without a test, hash-map iteration order or sort instability could silently break it. *Smallest follow-up:* Add an inline test that runs `wordpress.run` twice on `mini-wxr` and byte-compares all output files. *Confidence:* Confirmed gap.
2. **Malformed / truncated XML error-path test.**
*Observed:* No test for XML parse failures. *Why it matters:* A corrupted WXR should exit 3 cleanly, not panic. *Smallest follow-up:* Add a fixture with a truncated `export.xml` and assert the error propagates. *Confidence:* Confirmed gap.
3. **Symlink rejection in WP media tree.**
*Observed:* `isSymlink` check is present but not confirmed as tested specifically in `wordpress.zig` inline tests (as opposed to `assetfilename.zig` tests). *Why it matters:* Symlink escape risk is a security boundary. *Smallest follow-up:* Add a `fixtures/media-wxr` variant with a symlinked media file and assert `symlinkescape` appears in manifest. *Confidence:* Likely needed.
4. **`--out` as sub-path of media directory.**
*Observed:* Current guard only checks equality; a sub-path of media as output is not caught. *Why it matters:* Could cause the tool to scan its own output in subsequent runs. *Smallest follow-up:* Add guard in `main.zig` or document the limitation. *Confidence:* Uncertain whether exploitable in practice.
5. **Allocation-failure path coverage.**
*Observed:* No OOM tests. *Why it matters:* Very large WXR files could exhaust memory; error path should be clean. *Confidence:* Uncertain priority.

### Implementation follow-up

1. **Silent stale-output delete failure.**
*Observed:* `Io.Dir.cwd.deleteTree(io, contentpath) catch {}` swallows errors. *Why it matters:* On permission errors, the tool silently mixes old and new output. *Smallest follow-up:* Convert to `catch |err| std.log.warn(...)` to at least inform the user. *Confidence:* Confirmed behavior; whether to treat as a defect depends on intended failure semantics.
2. **Provenance comment field escaping.**
*Observed:* WXR metadata values (title, postname, etc.) are embedded in HTML comments without escaping `-->`. *Why it matters:* A post title containing `-->` would break the HTML comment structure in the output Markdown. *Smallest follow-up:* Escape `-->` as `-\->` or equivalent in provenance comment emission. *Confidence:* Likely; severity depends on whether downstream processors parse HTML comments.
3. **Staged media copy (atomicity).**
*Observed:* Media files are copied directly to destination; no staging. *Why it matters:* A crash mid-copy leaves a partial file. *Smallest follow-up:* Copy to `<dest>.tmp` then rename. *Confidence:* Uncertain whether this is a practical concern given single-process execution.

***
