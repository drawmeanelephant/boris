---
title: "`tools/source-rag/main.zig` evidence and cases"
id: docs/tools/source-rag/main/evidence-and-cases
parent: docs/tools/source-rag/main
status: draft
tags: [boris, zig, tools, evidence, source-rag, main]
---

# `tools/source-rag/main.zig` evidence and cases

## Operational walkthroughs

### Default full source-RAG generation

**Invocation:**
`zig build source-rag` or `zig-out/bin/boris-source-rag`

**Inputs:**
The current directory as `--root=.`, profile `all`, default candidate roots, accepted text extensions, `max_bytes=524288`, and `split_size=524288`.

**Execution path:**
`main` → `parseOptions` → `exportCorpus` → `collectSourcePaths` → `exportPackTree` → per-file rendering, bundle rendering, sidecar emission → `publishManagedCorpus`.

**Outputs:**
`files/`, three bundle categories, `INDEX.md`, `UPLOAD-GUIDE.md`, `catalog.jsonl`, `catalog_meta.json`, `profile_manifest.json`, and `part_manifest.json`. `upload_manifest.json`, `pack_manifest.json`, and `packs/` are omitted.

**Deterministic properties:**
Sorted source paths, sorted catalog, fixed group order, fixed field order, no timestamps, no random IDs.

**Failure behavior:**
Individual source reads may be skipped. Fatal root, allocation, serialization, output, or publication errors return process exit `3`.

**Evidence strength:**
Directly demonstrated for a synthetic fixture, with current test execution unverified.

**Residual gap:**
Actual repository scale, build invocation, cross-platform output, and current test pass status remain unverified.

### Profile-limited generation

**Invocation:**
`zig-out/bin/boris-source-rag --profile=core`
`zig-out/bin/boris-source-rag --profile=docs`
`zig-out/bin/boris-source-rag --profile=tools`

**Inputs:**
Only the profile’s candidate roots. Root files are included for `core`, but not for `docs` or `tools`.

**Execution path:**
The profile changes `scanDirsForProfile` and root-file eligibility before the common export pipeline.

**Outputs:**
The same artifact classes as flat default mode, limited to accepted files in the selected scope.

**Deterministic properties:**
Profile scopes are fixed arrays, and tests assert exact partitioning of default scan directories.

**Failure behavior:**
Unknown profile values are usage errors. Missing candidate directories are silently absent rather than fatal.

**Evidence strength:**
Directly demonstrated for profile mapping and exact pack/profile correspondence.

**Residual gap:**
No full generated golden corpus for each profile was available.

### Bundles-only generation

**Invocation:**
`zig build source-rag -- --bundles-only`

**Inputs:**
Normal selected sources and bundle settings.

**Execution path:**
`Options.includePerFileDocs` returns false. Sources are still read, cataloged, copied into bundle-memory structures, and counted. `exportUploadManifest` runs after all other sidecars and bundles have been written.

**Outputs:**
Combined bundles, `INDEX.md`, `UPLOAD-GUIDE.md`, catalogs, normal manifests, and `upload_manifest.json`. The `files/` tree is omitted and any previous managed `files/` tree is retired on successful publication.

**Deterministic properties:**
A test performs two bundles-only exports and compares every managed output file byte for byte.

**Failure behavior:**
Staging and publication behavior matches other modes. A prior valid corpus remains installed when the test-only failure occurs before publication.

**Evidence strength:**
Directly demonstrated by a comprehensive fixture test, with execution status unverified here.

**Residual gap:**
No failure injection occurs during upload-manifest sizing or the publication rename sequence.

### Per-file generation without bundles

**Invocation:**
`zig-out/bin/boris-source-rag --no-bundles`

**Inputs:**
Normal selected sources.

**Execution path:**
Per-file documents are emitted, while `exportBundles` is skipped. `part_manifest.json` records `"bundles":false` and an empty `parts` array.

**Outputs:**
`files/`, index, upload guide, catalog, metadata, profile manifest, and empty part manifest. Recognized previous bundle files are removed after successful publication.

**Deterministic properties:**
Per-file and catalog ordering remain sorted.

**Failure behavior:**
Same common staging and publication behavior.

**Evidence strength:**
Directly demonstrated for bundle removal and empty part manifest.

**Residual gap:**
No byte-for-byte repeated-run comparison is dedicated solely to no-bundles mode.

### Tool-segmented pack generation

**Invocation:**
`zig-out/bin/boris-source-rag --pack-by=tool`

**Inputs:**
The selected profile’s sorted source paths.

**Execution path:**
`partitionPacks` assigns each path to `core`, `docs`, `tooling`, or a dynamic `tools-<name>` pack. `exportPackTree` runs independently inside each pack. `exportPackRouter` then writes the root router.

**Outputs:**
Root `INDEX.md`, root `pack_manifest.json`, and `packs/<name>/` trees. Each pack contains its own index, upload guide, catalog, manifests, and configured file or bundle artifacts.

**Deterministic properties:**
Every path is assigned once, pack names are sorted, and tool pack names derive from repository paths.

**Failure behavior:**
Failure in any pack prevents publication of the staged pack tree. The previous published managed corpus remains in place until publication starts.

**Evidence strength:**
Directly demonstrated for dynamic tool discovery, exact profile composition, self-contained pack sidecars, and stale pack retirement.

**Residual gap:**
No test injects failure after several packs have staged or during pack-tree publication.

### Custom split-size generation

**Invocation:**
`zig-out/bin/boris-source-rag --split-size=262144`

**Inputs:**
Positive decimal target size.

**Execution path:**
Accepted source lists are partitioned into contiguous parts. A part closes before adding a file that would exceed the target, except that a single oversized source remains whole.

**Outputs:**
Potentially more or fewer bundle part files. `catalog_meta.json`, `part_manifest.json`, and `upload_manifest.json` record the configured target.

**Deterministic properties:**
Given the same ordered accepted files and target, boundaries and names are deterministic.

**Failure behavior:**
Zero or nonnumeric values are usage errors. Arithmetic uses `usize`; parsed overflow becomes `InvalidValue`.

**Evidence strength:**
Directly demonstrated for partition order, whole-file handling, and oversized files.

**Residual gap:**
No boundary fuzzing or maximum-`usize` stress test is present.

### Help and usage path

**Invocation:**
`zig-out/bin/boris-source-rag --help`

**Inputs:**
Process arguments only.

**Execution path:**
`parseOptions` returns immediately with `help=true`; `main` prints usage.

**Outputs:**
No corpus. Usage text is written through `std.debug.print`.

**Deterministic properties:**
Fixed compile-time text.

**Failure behavior:**
Returns exit `0`. Arguments after the help flag are ignored by parsing.

**Evidence strength:**
Structurally checked and covered by parser test.

**Residual gap:**
The exact output stream and process-level capture are not tested.

### Invalid CLI invocation

**Invocation:**
Representative: `zig-out/bin/boris-source-rag --profile=bogus`

**Inputs:**
Unknown flags, missing values, invalid enum names, zero split size, or incompatible bundle flags.

**Execution path:**
`parseOptions` returns `ParseError`; `main` selects a diagnostic, prints usage, and returns exit `2`.

**Outputs:**
No corpus should be staged.

**Deterministic properties:**
Error categories are fixed.

**Failure behavior:**
Plain log message plus full usage text.

**Evidence strength:**
Direct parser tests and structurally checked `main` mapping.

**Residual gap:**
No process-level test asserts exact diagnostics or exit status.

### Staging or publication failure

**Invocation:**
Programmatic test call with `test_fail_after_stage_writes`, or a real filesystem error.

**Inputs:**
A valid prior output may already exist.

**Execution path:**
Generation occurs in the stage tree. Before publication, stage failure triggers `errdefer` cleanup. During publication, prior managed artifacts move to recovery, staged artifacts move to output, and rollback is attempted on errors.

**Outputs:**
Before-publication failure leaves the prior managed output untouched. Successful publication replaces only managed artifacts. A restoration failure may leave recovery material or partial managed output.

**Deterministic properties:**
The test-only failure point is deterministic.

**Failure behavior:**
Error propagates to `main`, which logs the error name and exits `3`.

**Evidence strength:**
Directly demonstrated for staging failure; structurally checked for publication rollback.

**Residual gap:**
Rename, deletion, and restore failures are not injected or tested.

## Control flow

```text
process entry
    → obtain process arena, general allocator, I/O context, and arguments
    → copy argument slices into an ArrayList
    → parse CLI options
        → help: print usage and exit 0
        → parse error: print diagnostic and usage, exit 2
    → open caller-selected repository root
    → derive lexical output-skip prefix
    → discover candidate root files and directory entries
        → skip fixed directory names and root-only excluded trees
        → retain included regular-file extensions
        → sort source-relative paths
        → deduplicate paths
    → create clean sibling staging directory
    → choose output segmentation
        → pack-by=none:
            → export one corpus tree from all selected paths
        → pack-by=tool:
            → assign each path to one pack
            → sort packs by name
            → export one complete corpus tree per pack
            → write root INDEX router and pack_manifest.json
    → for each corpus tree:
        → optionally create files/
        → for each sorted source path:
            → read entire file
            → skip unreadable, oversized, or binary-looking file
            → derive language, rag_id, and rag_path
            → optionally render and write per-file Markdown
            → retain source body for bundle generation
            → append catalog and packed-path records
        → optionally partition and render source/docs/content bundles
        → write UPLOAD-GUIDE.md
        → add meta catalog entries
        → sort catalog
        → write INDEX.md
        → write catalog.jsonl
        → write catalog_meta.json
        → write profile_manifest.json
        → write part_manifest.json
        → optionally write upload_manifest.json
    → publish managed staged artifacts
        → create output and recovery directories
        → move prior managed artifacts to recovery
        → move staged managed artifacts into output
        → on install failure, delete new managed artifacts and restore previous ones
        → best-effort cleanup of stage and recovery directories
    → print summary and exit 0
```

## Tests, fixtures, and evidence coverage

The file contains 23 inline tests and three test helpers. The tests construct temporary repository trees through Zig filesystem APIs rather than relying on tracked external fixtures. No separate expected-output files or golden directories are referenced.

The source suite is substantial, but it could not be executed during this analysis because `zig` was unavailable. “Directly demonstrated” below means the inline test performs the stated operation and assertion, contingent on the current suite compiling and passing.

| Test or fixture                                                                                                  | Scope                    | Property demonstrated                                                                                                                                                    | Evidence strength         | Not demonstrated                                  |
| ---------------------------------------------------------------------------------------------------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------- | ------------------------------------------------- |
| `parseOptions: help and defaults`                                                                                | CLI parser               | Defaults, help, quiet, profile, output/root, max bytes, split size, no-bundles, bundles-only                                                                             | Directly demonstrated     | Process-level diagnostics                         |
| `parseOptions: unknown flag`                                                                                     | CLI parser               | Unknown flag, bad profile, zero split size, incompatible bundle flags                                                                                                    | Directly demonstrated     | Every malformed argument combination              |
| `profiles keep their documented scopes`                                                                          | Profile configuration    | Exact profile names and directory arrays                                                                                                                                 | Directly demonstrated     | Actual repository contents                        |
| `langFromPath and extensions`                                                                                    | Discovery helpers        | Language mapping, extension inclusion, skip rules, output-prefix and root-tree behavior                                                                                  | Directly demonstrated     | Malicious or non-UTF-8 filenames                  |
| `ragPathForSource avoids double md`                                                                              | Output path mapping      | Markdown sources do not receive `.md.md`                                                                                                                                 | Directly demonstrated     | Path containment                                  |
| `fenceLenFor handles nested fences`                                                                              | Markdown rendering       | Fence grows beyond source backtick runs                                                                                                                                  | Directly demonstrated     | Filenames or frontmatter injection                |
| `bundle partition is ordered, whole-file, and oversized-safe`                                                    | Bundle partition         | Ordered contiguous parts, byte totals, oversized whole source, naming, kind mapping                                                                                      | Directly demonstrated     | Large-scale boundaries and overflow               |
| `looksBinary`                                                                                                    | Binary filter            | Plain text accepted, early NUL rejected                                                                                                                                  | Directly demonstrated     | NUL after 8192 bytes or other binary encodings    |
| `renderSourceDocument wraps body`                                                                                | Per-file rendering       | Frontmatter source path and fenced body                                                                                                                                  | Directly demonstrated     | Complete serialized golden output                 |
| `exportCorpus mini fixture`                                                                                      | End-to-end flat export   | Discovery, vendor exclusion, binary skip, artifacts, empty categories, stale cleanup, failure-before-publication preservation, repeated-run bytes, no-bundles transition | Directly demonstrated     | Publish rename failure, cross-platform output     |
| `profile scopes partition the default scan exactly`                                                              | Profile invariants       | Each default directory belongs to exactly one scoped profile                                                                                                             | Directly demonstrated     | Root-file classification beyond current constants |
| `packNameForPath follows the declared profile scopes`                                                            | Pack assignment          | Core/docs/tooling mapping and dynamic per-tool names                                                                                                                     | Directly demonstrated     | Unsafe tool names or path punctuation             |
| `partitionPacks is exhaustive and disjoint`                                                                      | Pack partition           | No dropped or duplicated paths, sorted packs                                                                                                                             | Directly demonstrated     | Duplicate input paths after discovery             |
| `packs reproduce the declared profile scopes exactly`                                                            | Profile-pack equivalence | Pack unions equal profile scans                                                                                                                                          | Directly demonstrated     | Real repository drift outside defaults            |
| `parseOptions: pack-by`                                                                                          | CLI parser               | Pack-axis forms and errors                                                                                                                                               | Directly demonstrated     | Process-level usage output                        |
| `pack-by=tool discovers a tool pack with no code change`                                                         | End-to-end packs         | Dynamic tool discovery, router and manifest, docs/content grouping                                                                                                       | Directly demonstrated     | Removal or failure during same test               |
| `pack-by=none emits the historical flat tree and no pack artifacts`                                              | Mode compatibility       | Flat tree omits pack artifacts; flat and pack totals match                                                                                                               | Directly demonstrated     | Complete byte identity with a historical release  |
| `each pack carries its own manifests and composes with split-size and bundles-only`                              | Pack composition         | Self-contained sidecars, no `files/`, per-pack splitting                                                                                                                 | Directly demonstrated     | Upload-manifest content in every pack             |
| `generated router artifacts name no vendor or product`                                                           | Generated prose          | Selected tool-authored files omit listed vendor names; token approximation is labeled                                                                                    | Directly demonstrated     | Arbitrary vendor terms or packed source content   |
| `a pack that disappears is not stranded in the published output`                                                 | Stale pack cleanup       | Removed source tool produces no stale output pack                                                                                                                        | Directly demonstrated     | Failure during pack replacement                   |
| `approxTokensFromBytes uses floor chars/4`                                                                       | Token heuristic          | Exact floor division examples                                                                                                                                            | Directly demonstrated     | Accuracy against a tokenizer                      |
| `exportCorpus default mode still emits files/`                                                                   | Default regression       | Default emits per-file tree and bundles, not upload manifest                                                                                                             | Directly demonstrated     | Complete default corpus bytes                     |
| `exportCorpus bundles-only omits files/, removes stale files/, is deterministic, and keeps manifests consistent` | End-to-end bundles-only  | Stale tree removal, artifact set, order, sizes, totals, manifest consistency, unrelated sibling preservation, repeated-run identity, transition back to default          | Directly demonstrated     | Publish rollback and huge corpus behavior         |
| `writeMiniSourceRagFixture`                                                                                      | Test fixture helper      | Creates root, source, and source-RAG tool files                                                                                                                          | Fixture evidence          | Repository-realistic complexity                   |
| `writePackByToolFixture`                                                                                         | Test fixture helper      | Creates core, docs, content, and dynamic tool shapes                                                                                                                     | Fixture evidence          | Tool names with unsafe characters                 |
| `expectOutputFileEqual`                                                                                          | Test helper              | Reads and compares complete generated bytes                                                                                                                              | Supporting test mechanism | Independent golden files                          |

No visible test covers:

* actual CLI process execution and exit-code capture;
* `printUsage` output bytes;
* allocation failure at each allocation point;
* publication rename or restore failure;
* permissions failure;
* symlinked roots, outputs, or entries;
* absolute output inside the scan root;
* `.` or `..` normalization;
* malicious filenames;
* invalid UTF-8 paths or source bodies;
* NUL bytes after the initial 8192-byte window;
* very large repository totals;
* cross-platform CI;
* external schema validation;
* compatibility with older generated output;
* root and standalone build steps.
