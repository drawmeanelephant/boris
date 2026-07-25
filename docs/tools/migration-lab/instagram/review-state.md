---
title: "`tools/migration-lab/instagram.zig` review state"
id: docs/tools/migration-lab/instagram/review-state
parent: docs/tools/migration-lab/instagram
status: draft
tags: [boris, zig, tools, review-state, migration-lab, instagram]
---

# `tools/migration-lab/instagram.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **`mediamanifest.json` schema:** the per-entry field list is mentioned in the README for WordPress mode with considerable detail; the Instagram equivalent is less explicitly documented. A schema note matching the WordPress pattern would reduce uncertainty. *(Likely needed; confidence: likely.)*
- **`report.json` field enumeration:** a complete stable-fields list analogous to the WordPress schema-3 note in the README would clarify consumer contracts. *(Confidence: likely.)*
- **Percent-encoded URI behavior:** the README does not address whether `%2e%2e` in media URIs is handled. A one-sentence note would eliminate ambiguity. *(Confidence: confirmed gap.)*
- **`source_role` metadata:** this dossier uses `developer-tool-module` as `source_role`; the prompt template suggests `developer-tool-emitter` may be more appropriate given the file emits Markdown and JSON. Confirm the right classification for the template family. *(Confidence: uncertain.)*


### Test follow-up

- **Repeated-run determinism test for Instagram mode:** other modes (Astro, Starlight) have explicit second-run byte-comparison tests; Instagram does not (or the test is not confirmed). Adding a `run A; run B; expect A == B` test would confirm determinism. *(Evidence: absence pattern; importance: high for migration tool confidence; confidence: confirmed gap.)*
- **Unit tests for `isSafeMediaUri`:** the function is public and has well-defined logic; a table-driven unit test covering `..`, `/`, `\`, drive prefix, empty, and valid cases would give stronger evidence than fixture integration alone. *(Confidence: confirmed gap.)*
- **Unit tests for `repairMetaEscapedUtf8` and `hasMojibakeResidue`:** the encoding repair logic is non-trivial and affects provenance classification. Direct unit tests with known inputs (the `posts2.json` caption, a doubly-encoded input, a genuinely mixed input) would strengthen confidence. *(Confidence: confirmed gap.)*
- **Source immutability test:** confirm that no file under `--dump` is modified by running before/after byte comparison as other modes do. *(Confidence: likely needed.)*
- **Allocator leak resolution:** the `main.zig` comment notes the leak; identifying and fixing it would allow `refAllDecls` to include Instagram mode, closing the coverage gap. *(Evidence: explicit comment; confidence: confirmed.)*
- **Symlink traversal test in hostile fixture:** add a symlink in `fixtures/hostile-instagram/` pointing outside the fixture tree and confirm the tool either rejects or safely handles it. *(Confidence: uncertain need — depends on whether the platform testing environment supports symlinks.)*


### Implementation follow-up

- **Percent-encoded URI decoding in `isSafeMediaUri`:** if Meta exports can produce percent-encoded paths (not confirmed), a decode step before the traversal check would close the residual gap. *(Evidence: gap identified; need uncertain pending Meta export format confirmation.)*
- **`--out` prefix containment check:** the current check is string equality only. A prefix-containment check (similar to `refuseOutputInsideSource` in `themearchaeology.zig`) would close the gap where `--dump` is a prefix of `--out` or vice versa. *(Evidence: `refuseOutputInsideSource` pattern exists in sibling module; confidence: likely useful.)*
- **Per-file memory cap in `readFileAlloc`:** replacing `.unlimited` with a configurable or default cap would reduce resource exhaustion risk from adversarially large files. *(Confidence: uncertain need — depends on expected export sizes.)*

***
