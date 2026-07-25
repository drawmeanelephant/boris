---
title: "`tools/source-rag/main.zig` review state"
id: docs/tools/source-rag/main/review-state
parent: docs/tools/source-rag/main
status: draft
tags: [boris, zig, tools, review-state, source-rag, main]
---

# `tools/source-rag/main.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

| Observed evidence                                                                                              | Why the gap matters                                                        | Smallest plausible follow-up                                                                                               | Need                                              |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| Source text names `zig build source-rag`, a direct executable, and Zig 0.16+, but build files were unavailable | Users cannot distinguish implemented commands from stale embedded guidance | Document the exact root and standalone build steps beside their declarations                                               | Confirmed documentation gap in available evidence |
| `profile_manifest.json`, `part_manifest.json`, and `upload_manifest.json` have no explicit format identifiers  | Consumers cannot negotiate compatibility from the files themselves         | Publish a short schema contract stating whether these formats are internal, versioned elsewhere, or intentionally unstable | Likely                                            |
| Token methods are labeled `chars/4` in one manifest and `bytes/4` in another, while both use byte length       | Consumers may read the labels as different algorithms                      | Document one canonical term and explain any retained compatibility label                                                   | Confirmed terminology discrepancy                 |
| The source comment uses “atomic publish,” while rollback can fail and cleanup is best effort                   | Documentation may overstate the guarantee                                  | Replace or qualify the term with “staged managed-artifact replacement with rollback”                                       | Confirmed wording issue                           |
| Generated Markdown inserts raw source paths into frontmatter and headings                                      | Consumers lack a filename trust contract                                   | Document supported filename assumptions and downstream escaping expectations                                               | Likely                                            |
| No digest or fingerprint exists                                                                                | Consumers may assume byte counts prove integrity                           | State explicitly that byte counts are informational and no content integrity hash is provided                              | Confirmed                                         |
| Generated artifacts are described as source knowledge packs                                                    | Readers could mistake them for normative documentation                     | Repeat in tool documentation that source and tracked contracts remain authoritative                                        | Confirmed and already partially present           |

### Test follow-up

| Observed evidence                                                                | Why the gap matters                                                    | Smallest plausible follow-up                                                             | Need                                        |
| -------------------------------------------------------------------------------- | ---------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ------------------------------------------- |
| Staging failure is injected, but publication rename and restore failures are not | The strongest filesystem guarantee depends on rollback branches        | Add an injectable filesystem-operation seam or focused publication-state tests           | Likely                                      |
| No process-level CLI tests exist                                                 | Parser tests do not verify output streams and exit codes               | Run the built executable against help, unknown-flag, and I/O-error cases                 | Likely                                      |
| No absolute-output-inside-root fixture exists                                    | Lexical output self-skip can differ from filesystem containment        | Add fixtures for relative, absolute, `./`, and `..` spellings of the same output         | Likely                                      |
| No symlink fixtures exist                                                        | Root, output, and entry behavior may differ by platform                | Add explicit symlink-policy tests on supported platforms                                 | Likely                                      |
| No malicious-filename fixture exists                                             | Raw Markdown paths and terminal output create parser and display risks | Test newline, quote, backtick, control, and Unicode filenames where supported            | Likely                                      |
| Binary detection checks only an early NUL                                        | Binary files without early NUL may be packed                           | Add tests documenting the intended heuristic boundary, including NUL after byte 8192     | Confirmed coverage gap                      |
| No allocation-failure tests exist                                                | Manual ownership spans many buffers and transfer points                | Use failing allocators around render, partition, pack, and publication preparation paths | Likely                                      |
| `max_bytes` is checked after unlimited read                                      | Large-file behavior is not validated under constrained memory          | Add a sparse or large-file test measuring whether the documented limit bounds allocation | Confirmed behavior gap                      |
| Cross-platform CI evidence was unavailable                                       | Filesystem entry kinds and path APIs may vary                          | Run the suite on every supported OS and compare generated fixtures                       | Uncertain until platform support is defined |
| No external schema validation occurs                                             | Handwritten JSON can drift unnoticed                                   | Parse each generated JSON file with a standard parser and validate required fields       | Likely                                      |

### Implementation follow-up

| Observed evidence                                                            | Why the gap matters                                                            | Smallest plausible follow-up                                                                                           | Need                                            |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------- |
| `readFileAlloc` reads the complete file before comparing with `max_bytes`    | The option does not bound read allocation or protect against huge files        | Stat the file first or use a bounded reader, then retain the existing skip behavior                                    | Likely                                          |
| Output exclusion performs lexical prefix comparison without canonicalization | A custom absolute output beneath the scan root may be rediscovered             | Resolve a repository-relative contained output path when possible, or explicitly reject ambiguous in-root output paths | Likely                                          |
| Markdown frontmatter and headings use unescaped source paths                 | Adversarial filenames can alter generated document structure                   | Quote or escape frontmatter scalars and encode heading or inline-code paths safely                                     | Likely                                          |
| Publication restoration can fail after managed paths have moved              | A previous valid output is not absolutely guaranteed under compounded failures | Preserve a durable recovery marker and document or improve resumable restoration                                       | Uncertain; no observed real failure             |
| Several machine formats lack identifiers                                     | Consumers cannot mechanically distinguish future revisions                     | Add explicit `format` and `schema_version` fields if these files are intended as interfaces                            | Uncertain; depends on contract intent           |
| No content digest exists                                                     | Uploads cannot be independently checked against the scanned bytes              | Add per-source hashes only if downstream integrity verification is a requirement                                       | Uncertain                                       |
| Raw source paths are logged to the terminal                                  | Control characters may disturb diagnostic output                               | Escape control bytes in progress and error path rendering                                                              | Likely for untrusted repositories               |
| File bodies for a whole pack are retained and bundles are assembled in full  | Large repositories can require high peak memory                                | Stream rendered documents and bundle parts where compatible with deterministic partitioning                            | Uncertain; depends on expected repository scale |

None of these implementation items is presented as a confirmed production defect. They are evidence-grounded gaps, risk boundaries, or possible hardening work.
