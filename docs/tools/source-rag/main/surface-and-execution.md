---
title: "`tools/source-rag/main.zig` surface and execution"
id: docs/tools/source-rag/main/surface-and-execution
parent: docs/tools/source-rag/main
status: draft
tags: [boris, zig, tools, surface, source-rag, main]
---

# `tools/source-rag/main.zig` surface and execution

## CLI surface

`parseOptions` starts at argument index one when an executable-name element is present. No positional arguments are accepted. Except for `--help`, parsing continues through all arguments and validates the mutual exclusion of `--no-bundles` and `--bundles-only` at the end (`main.zig:224-292`).

| Argument or flag                    | Required           | Default      | Accepted values                                | Effect                                                                                | Failure behavior                                                                                 |
| ----------------------------------- | ------------------ | ------------ | ---------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `-h`, `--help`                      | No                 | `false`      | Flag only                                      | Sets help and returns immediately from parsing; later arguments are not checked       | `main` prints usage and exits `0`                                                                |
| `-q`, `--quiet`                     | No                 | `false`      | Flag only                                      | Suppresses progress lines printed by `log`                                            | Does not suppress final `std.log.err` diagnostics                                                |
| `--no-bundles`                      | No                 | `false`      | Flag only                                      | Omits combined Markdown bundle files; retains per-file documents and sidecars         | Combined with `--bundles-only` produces `InvalidValue`, unless parsing already returned for help |
| `--bundles-only`                    | No                 | `false`      | Flag only                                      | Emits bundles and sidecars while omitting `files/`; also emits `upload_manifest.json` | Combined with `--no-bundles` produces `InvalidValue`                                             |
| `--profile=NAME`                    | No                 | `all`        | `all`, `core`, `docs`, `tools`                 | Selects the input scope                                                               | Empty value gives `MissingValue`; unknown value gives `InvalidValue`                             |
| `--profile NAME`                    | No                 | `all`        | `all`, `core`, `docs`, `tools`                 | Same as equals form                                                                   | Missing or empty following value gives `MissingValue`                                            |
| `--pack-by=AXIS`                    | No                 | `none`       | `none`, `tool`                                 | Selects flat output or self-contained pack trees                                      | Empty value gives `MissingValue`; unknown value gives `InvalidValue`                             |
| `--pack-by AXIS`                    | No                 | `none`       | `none`, `tool`                                 | Same as equals form                                                                   | Missing or empty following value gives `MissingValue`                                            |
| `--out=DIR`                         | No                 | `source-rag` | Any nonempty byte string accepted by path APIs | Chooses output root; stage and recovery siblings are derived from it                  | Empty value gives `MissingValue`; filesystem failures later exit `3`                             |
| `--out DIR`                         | No                 | `source-rag` | Any nonempty value                             | Same as equals form                                                                   | Missing or empty value gives `MissingValue`                                                      |
| `--root=DIR`                        | No                 | `.`          | Any nonempty byte string accepted by path APIs | Chooses the directory opened as the scan root                                         | Empty value gives `MissingValue`; open failure later exits `3`                                   |
| `--root DIR`                        | No                 | `.`          | Any nonempty value                             | Same as equals form                                                                   | Missing or empty value gives `MissingValue`                                                      |
| `--max-bytes=N`                     | No                 | `524288`     | Base-10 `usize`, including zero                | Files larger than the value are skipped after being read                              | Empty value gives `MissingValue`; parse overflow or nonnumeric input gives `InvalidValue`        |
| `--split-size=N`                    | No                 | `524288`     | Positive base-10 `usize`                       | Sets target source-body bytes per bundle part                                         | Empty gives `MissingValue`; zero, overflow, or nonnumeric input gives `InvalidValue`             |
| `--split-size N`                    | No                 | `524288`     | Positive base-10 `usize`                       | Same as equals form                                                                   | Missing or empty gives `MissingValue`; invalid number gives `InvalidValue`                       |
| Positional argument or unknown flag | Not accepted       | None         | None                                           | No defined positional command surface                                                 | `UnknownFlag`, usage text, exit `2`                                                              |
| `test_fail_after_stage_writes`      | Not a CLI argument | `null`       | Programmatic `?usize` only                     | Injects deterministic staging failure for tests                                       | Cannot be supplied through `parseOptions`                                                        |

`--max-bytes` has no separated-value form. A literal `--max-bytes 10` is parsed as an unknown flag followed by another unknown positional value.

Exit behavior is explicit:

| Exit code | Meaning                                                                          |
| --------: | -------------------------------------------------------------------------------- |
|       `0` | Help or successful export                                                        |
|       `2` | Argument acquisition, allocation during argument preparation, or CLI usage error |
|       `3` | Any error propagated from `exportCorpus`                                         |

Read failures for individual source files are not process-fatal. They increment `skipped` and allow generation to continue.

## Inputs and discovery model

`collectSourcePaths` opens the caller-selected root and constructs repository-relative paths from directory entries. Candidate paths are sorted ascending using `std.mem.order`, then deduplicated (`main.zig:483-576`).

### Profile scopes

* `all`: root files plus all default scan directories.
* `core`: root files plus `src` and `layouts`.
* `docs`: `docs` and `content`.
* `tools`: `scripts`, `tools`, `test`, `fixtures`, and `SUPPORT`.

The tests assert that every default scan directory belongs to exactly one of `core`, `docs`, or `tools`, and that the scoped lists do not claim extra directories (`main.zig:2606-2633`).

### Inclusion rules

Accepted extensions are:

`.zig`, `.md`, `.c`, `.h`, `.html`, `.htm`, `.json`, `.jsonl`, `.sh`, `.zon`, `.txt`, `.yml`, `.yaml`, `.toml`, `.css`, and `.svg`.

`LICENSE`, `LICENSE.txt`, `NOTICE`, and `COPYING` are accepted at any depth. Selected root files are considered explicitly even when extensionless.

Directory names skipped anywhere include `.git`, Zig caches and outputs, `dist`, `test-output`, `.boris`, `.release-gate`, `node_modules`, generic `build`, and `CMakeFiles`. Root-level generated or third-party trees skipped by prefix include `rag`, `rag1`, `rag2`, `source-rag`, `dist`, `zig-out`, `test-output`, and `vendor`.

The configured output path is also excluded when a discovered repository-relative path equals or is beneath the normalized `out_skip` string. Normalization only strips a leading `./`.

### Read-time filtering

Discovery includes regular files by name and extension. During export, each file is read completely. It is then skipped if:

* reading failed;
* its body length exceeds `max_bytes`;
* a NUL byte appears within the first 8192 bytes.

The implementation does not pre-stat a file before the unlimited read. `max_bytes` therefore limits packaging, not peak allocation while reading.

| Input category                        | Discovery rule                                                 | Included by default            | Exclusions                                                                                | Evidence                                                 |
| ------------------------------------- | -------------------------------------------------------------- | ------------------------------ | ----------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| Root project guidance and build files | Explicit names, only for `all` and `core`                      | Yes when present               | Configured output path                                                                    | `main.zig:123-133`, `522-541`                            |
| Compiler sources                      | Walk `src/`                                                    | `all`, `core`                  | Skip directories, generated top-level trees, extension filter                             | `main.zig:110-175`, `483-576`                            |
| Layouts                               | Walk `layouts/`                                                | `all`, `core`                  | Same generic exclusions                                                                   | `main.zig:110-175`                                       |
| Documentation                         | Walk `docs/`                                                   | `all`, `docs`                  | Generic exclusions; `docs/rag/` is intentionally not excluded by the root-only `rag` rule | `main.zig:154-175`, `483-576`                            |
| Product content                       | Walk `content/`                                                | `all`, `docs`                  | Generic exclusions                                                                        | `main.zig:110-175`                                       |
| Tool sources                          | Walk `tools/`                                                  | `all`, `tools`                 | Generic build/cache names; `tools/source-rag/` is retained                                | `main.zig:136-175`, `483-576`                            |
| Scripts, tests, fixtures, support     | Walk corresponding profile directories                         | `all`, `tools`                 | Generic exclusions                                                                        | `main.zig:110-175`                                       |
| Vendored source                       | Root-level `vendor/` is excluded                               | No                             | Entire root vendor tree                                                                   | `main.zig:154-165`, tests at `2263-2281` and `2363-2548` |
| Prior generated corpus                | Excluded by fixed top-level names and configured output prefix | No for normal default location | Absolute or nonmatching custom output paths may escape configured-prefix exclusion        | `main.zig:461-480`, `522-576`, `1896-1914`               |
| Unsupported extensions                | Not appended during discovery                                  | No                             | Anything outside the allowlist and extensionless special names                            | `main.zig:177-199`, `356-366`                            |
| Binary-looking files                  | Initially discovered by extension, then skipped                | No after filtering             | NUL in first 8192 bytes                                                                   | `main.zig:418-424`, `2019-2027`                          |
| Oversized files                       | Initially discovered and fully read, then skipped              | No after filtering             | Body length greater than `max_bytes`                                                      | `main.zig:579-584`, `2013-2023`                          |

The implementation does not inspect Git tracking or ignore state. “Tracked” and “ignored” status are therefore unknown to the exporter.

Direct directory entries whose kind is neither `.directory` nor `.file` are ignored. This appears to exclude ordinary symlink entries during recursive discovery, but no explicit symlink contract or test is present. The caller-selected root and output paths may themselves resolve through symlinks.

Empty source categories are represented differently depending on mode:

* Flat exports with bundles enabled emit an empty bundle for every empty bundle category.
* `partitionBundleFiles` creates one empty part for an empty category.
* Pack mode creates only packs represented by at least one discovered path.
* `--no-bundles` emits an empty `parts` array instead of empty bundle files.

## Output artifact model

### Flat output

| Artifact                                   | Format                                                     | Ownership                            | Ordering guarantee                                          | Consumer                                 | Stability                                                            |
| ------------------------------------------ | ---------------------------------------------------------- | ------------------------------------ | ----------------------------------------------------------- | ---------------------------------------- | -------------------------------------------------------------------- |
| `files/<source>.md`                        | Markdown with YAML-like frontmatter and fenced source body | Entire `files/` tree is managed      | Source paths originate from sorted discovery                | File-level retrieval or human inspection | Structure is implemented and tested; no explicit format version      |
| `INDEX.md`                                 | Markdown index                                             | Managed root file                    | Catalog rows and bundle rows use deterministic input order  | Human or model navigation                | Generated prose is not declared stable                               |
| `UPLOAD-GUIDE.md`                          | Markdown guidance                                          | Managed root file                    | Fixed authored text selected by options                     | Upload workflow                          | Not versioned                                                        |
| `catalog.jsonl`                            | One JSON object per line                                   | Managed root file                    | Sorted by `rag_path`                                        | Machine inventory                        | Field order fixed by implementation; no file-level schema identifier |
| `catalog_meta.json`                        | One-line JSON object                                       | Managed root file                    | Fixed field order                                           | Format metadata                          | `format=boris-source-rag`, `schema_version=1`                        |
| `profile_manifest.json`                    | One-line JSON object                                       | Managed root file                    | Packed paths retain sorted discovery order                  | Scope and source-path inventory          | Not explicitly versioned                                             |
| `part_manifest.json`                       | One-line JSON object                                       | Managed root file                    | Fixed bundle-kind order, then part order, then source order | Bundle routing                           | Not explicitly versioned                                             |
| `upload_manifest.json`                     | One-line JSON object                                       | Managed root file, bundles-only mode | Fixed sidecar order followed by part-manifest order         | Upload planning                          | Not explicitly versioned                                             |
| `boris-source-N.md`                        | Combined Markdown                                          | Managed by filename pattern          | Contiguous source-category order                            | Convenience upload bundle                | Not explicitly versioned                                             |
| `boris-docs.md` or `boris-docs-N.md`       | Combined Markdown                                          | Managed by filename pattern          | Contiguous docs-category order                              | Convenience upload bundle                | Not explicitly versioned                                             |
| `boris-content.md` or `boris-content-N.md` | Combined Markdown                                          | Managed by filename pattern          | Contiguous content-category order                           | Convenience upload bundle                | Not explicitly versioned                                             |

### Pack output

With `--pack-by=tool`, the root managed output contains:

* `INDEX.md`, serving as a router;
* `pack_manifest.json`;
* `packs/<pack-name>/`, with each pack containing its own flat corpus tree.

Pack names are `core`, `docs`, `tooling`, and dynamically discovered `tools-<name>` values. The complete `packs/` tree is managed as one unit so disappeared packs are removed on a later successful run.

### Temporary and recovery paths

* `<out>.boris-source-rag-stage`: contains the complete next managed corpus.
* `<out>.boris-source-rag-prev`: temporarily holds the previous managed corpus during publication.

Both are derived from `--out`, not configurable independently. Cleanup after a successful publication is best effort. A cleanup failure may leave one of these sibling trees.

### Artifact authority

`catalog.jsonl`, profile manifests, and part manifests are the principal machine records for one generated corpus, but they are not normative project records. `INDEX.md` and `UPLOAD-GUIDE.md` are human convenience documents. Combined bundles duplicate accepted source bodies already represented by per-file documents, unless `--bundles-only` intentionally omits the per-file tree.

For a normal full export, a minimally useful file-level upload is described by the generated guide as `INDEX.md`, selected `files/` content, and key guidance documents. For `--bundles-only`, the generated guide instead treats combined parts, index files, and manifests as the upload surface. These are workflow recommendations, not mechanically enforced requirements.

## Serialization and schema behavior

### Per-file Markdown

`renderSourceDocument` emits:

1. frontmatter containing `rag_id`, `rag_path`, `source_path`, `category`, `lang`, and original source byte count;
2. a heading containing the source path;
3. a fenced code block containing the source body.

The code-fence length is one greater than the longest run of backticks in the body, with a minimum of three. This prevents the source body itself from prematurely closing the chosen fence. If the original body does not end in a newline, one newline is inserted before the closing fence. The `bytes` field still records the original body length.

Frontmatter path values and headings are inserted without YAML, Markdown, or backtick escaping. The fence mechanism protects the body, not malicious filenames.

### JSON and JSONL

`jsonEscapeAppend` escapes quotes, backslashes, newline, carriage return, tab, and remaining control bytes below `0x20`. Other bytes are copied. Machine files are assembled manually in a fixed field order.

Every JSON or JSONL artifact ends with `\n`. `catalog.jsonl` emits one object and newline per entry. Empty collections are emitted as `[]`.

### Known formats

| Format or file              | Identifier or schema version                                              | Producer                | Ordering                                                 | Validation coverage                              |
| --------------------------- | ------------------------------------------------------------------------- | ----------------------- | -------------------------------------------------------- | ------------------------------------------------ |
| Per-file Markdown documents | Not versioned                                                             | `renderSourceDocument`  | Sorted source-path traversal                             | Fence and representative body test               |
| Combined Markdown bundles   | Not versioned                                                             | `renderBundle`          | Bundle kind order plus contiguous accepted-file order    | Partition and fixture assertions                 |
| `catalog_meta.json`         | `format: boris-source-rag`, `schema_version: 1`, `tool_version: 0.1.0`    | `exportCatalogMeta`     | Fixed fields                                             | Fixture checks format identifier                 |
| `catalog.jsonl`             | Metadata is external in `catalog_meta.json`; rows have no per-row version | `exportCatalogJsonl`    | Sorted by `rag_path`                                     | Fixture and repeated-run comparisons             |
| `profile_manifest.json`     | Not versioned                                                             | `exportProfileManifest` | Sorted packed path list                                  | Profile and fixture checks                       |
| `part_manifest.json`        | Not versioned                                                             | `exportPartManifest`    | Bundle groups, parts, and sources in deterministic order | Partition, consistency, and repeated-run checks  |
| `upload_manifest.json`      | Not versioned                                                             | `exportUploadManifest`  | Fixed sidecars followed by part order                    | Byte-size, order, total, and repeated-run checks |
| `pack_manifest.json`        | `format: boris-source-rag-packs`, `schema_version: 1`                     | `exportPackRouter`      | Pack names sorted                                        | Pack-discovery and neutral-prose checks          |
| Root pack router `INDEX.md` | Not versioned                                                             | `exportPackRouter`      | Sorted pack summaries                                    | Pack tests                                       |
| Upload guide                | Not versioned                                                             | `exportUploadGuide`     | Fixed option-selected text                               | Presence and repeated-run checks                 |

No digest, checksum, fingerprint, content hash, or source-tree hash is emitted. Byte counts are size metadata, not integrity proofs.

`catalog.jsonl` includes source entries plus two metadata entries for `INDEX.md` and `UPLOAD-GUIDE.md`. Those metadata rows use `bytes: 0`, not their actual serialized file sizes. Machine sidecars and bundle files are not catalog rows.

`part_manifest.json` records original source-body bytes. `upload_manifest.json` records actual on-disk generated-file sizes. `pack_manifest.json` records accepted source-body totals.

Two labels are used for the same token heuristic:

* `upload_manifest.json` writes `token_estimate_method: "chars/4"`;
* `pack_manifest.json` writes `token_estimate_method: "bytes/4"`.

Both implementations divide UTF-8 byte counts by four using integer floor. No parser or compatibility layer consumes these files in the target source, so version disagreement and backward-compatibility behavior are not implemented here.

## Determinism and reproducibility

| Property                     | Mechanism                                                      | Evidence strength     | Residual limitation                                                                                                         |
| ---------------------------- | -------------------------------------------------------------- | --------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Discovery order              | All discovered relative paths are sorted bytewise              | Structurally checked  | Filesystem contents and readable-file set remain environmental inputs                                                       |
| Duplicate suppression        | Adjacent equal paths are removed after sorting                 | Structurally checked  | No Unicode or case normalization                                                                                            |
| Catalog order                | Entries sorted by `rag_path`                                   | Structurally checked  | Equal-key behavior is not separately specified                                                                              |
| Pack order                   | Packs sorted by pack name                                      | Directly demonstrated | Test execution was not independently run                                                                                    |
| Paths within packs           | Input paths are already sorted and appended without reordering | Structurally checked  | Depends on `partitionPacks` receiving sorted input                                                                          |
| Bundle-kind order            | Fixed array: source, docs, content                             | Structurally checked  | Category assignment is path-prefix based                                                                                    |
| Bundle partitioning          | Contiguous whole-file ranges and fixed split target            | Directly demonstrated | Target is not a hard maximum for oversized files                                                                            |
| Whole-file preservation      | Source bodies are never split across parts                     | Directly demonstrated | Rendered documents may add a trailing newline outside the recorded body                                                     |
| Empty-category output        | One deterministic empty part when bundles are enabled          | Structurally checked  | Consumer expectations for empty bundles are undocumented                                                                    |
| JSON field order             | Handwritten append sequence                                    | Structurally checked  | No external schema or parser verifies compatibility                                                                         |
| JSON record newline          | Explicit newline after each record or document                 | Structurally checked  | Invalid UTF-8 source paths are not addressed                                                                                |
| Timestamps                   | None are emitted                                               | Structurally checked  | Filesystem metadata is not serialized                                                                                       |
| Random identifiers           | None are generated                                             | Structurally checked  | IDs derive directly from source paths                                                                                       |
| Absolute source paths        | Discovered paths are relative to opened root                   | Structurally checked  | User-selected root and output paths may be absolute; output self-skip can then be incomplete                                |
| Repeated flat run            | Representative managed artifacts compared byte for byte        | Directly demonstrated | Only one synthetic fixture and host environment                                                                             |
| Repeated bundles-only run    | All managed artifacts compared byte for byte                   | Directly demonstrated | No cross-platform repetition                                                                                                |
| Stale-output behavior        | Entire managed trees and recognized bundle files are replaced  | Directly demonstrated | Publication rollback failures are not tested                                                                                |
| Pack disappearance           | Entire `packs/` tree replacement removes vanished pack         | Directly demonstrated | No injected failure during pack-tree publication                                                                            |
| Cross-platform byte identity | No supported proof                                             | Uncertain             | Separator handling, filesystem ordering semantics, line handling, and Zig runtime behavior were not tested across platforms |

The source suite contains byte-for-byte repeated-run tests for normal flat mode and bundles-only mode. Since the Zig compiler was unavailable, this dossier verifies the assertions and control flow but not their current execution result.

Differences are intentionally allowed when the caller changes:

* profile;
* `pack_by`;
* `no_bundles`;
* `bundles_only`;
* split size;
* maximum accepted file size;
* root contents;
* readable-file set;
* output-related generated prose.

## Filesystem and path safety

Publication is scoped to a fixed set of managed root filenames, recognized bundle filename patterns, and two managed trees. Previous managed artifacts are moved into a recovery directory before staged artifacts are installed. Unknown siblings are left in place.

The source does not canonicalize `--root` or `--out`, reject absolute paths, reject `..`, verify output containment within a designated workspace, or consult version-control status. Safety against an incorrectly chosen output path therefore depends on caller discipline.

| Risk                                    | Mitigation                                                                             | Mechanically enforced | Tested                                            | Residual gap                                                                            |
| --------------------------------------- | -------------------------------------------------------------------------------------- | --------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Recursing into default generated output | Fixed root-level generated-tree exclusions and configured output-prefix check          | Partial               | Prefix behavior has unit checks                   | Absolute or differently spelled output paths under the root may not match               |
| Overwriting unrelated output siblings   | Only fixed managed names, bundle patterns, `files/`, and `packs/` are moved or removed | Yes                   | Yes, with `user-note.txt`                         | Name collision with a caller file using a managed name is treated as exporter ownership |
| Stale per-file documents                | Entire managed `files/` tree is replaced                                               | Yes                   | Yes                                               | None for successful publication                                                         |
| Stale disappeared packs                 | Entire managed `packs/` tree is replaced                                               | Yes                   | Yes                                               | None for successful publication                                                         |
| Stale old bundle parts                  | Recognized bundle names are enumerated and moved or deleted                            | Yes                   | Yes for no-bundles transition                     | Unrecognized historical names are preserved                                             |
| Failure during staging                  | Stage tree is separate; prior output is untouched                                      | Yes                   | Yes through injected failure                      | Allocation and every possible staging I/O branch are not injected                       |
| Failure while moving old output         | Restoration is attempted from recovery tree                                            | Partial               | No direct failure injection                       | Restoration can itself fail                                                             |
| Failure while installing staged output  | Newly moved managed files are deleted and previous artifacts restored                  | Partial               | No direct failure injection                       | `SourceRagPublishRestoreFailed` may leave partial output or recovery material           |
| Cleanup after successful publication    | Stage and recovery trees are removed best effort                                       | Partial               | Not specifically                                  | Harmless but stale sibling recovery material may remain                                 |
| Absolute or traversal output path       | No mitigation beyond filesystem API behavior                                           | No                    | No                                                | Caller can direct writes outside the repository                                         |
| Source-derived output traversal         | Source paths come from directory iteration and are joined beneath `files/`             | Mostly                | No malicious-name fixture                         | No explicit normalization or containment assertion                                      |
| Symlink traversal                       | Non-file and non-directory entries are ignored during ordinary walk                    | Partial               | No                                                | Root or output may be symlinked; platform entry semantics are unverified                |
| Cross-filesystem rename                 | Stage and recovery names are derived as output siblings                                | Partial               | No                                                | Lexical sibling construction is not a formal same-filesystem proof                      |
| Unreadable source file                  | Read error is logged and counted as skipped                                            | Yes                   | Indirectly covered by control flow, not a fixture | Corpus may be incomplete while process still succeeds                                   |
| Unwritable output                       | Error propagates to `main`                                                             | Yes                   | No                                                | Publication may require recovery                                                        |
| Output inside source tree               | Prefix skip aims to avoid recursion                                                    | Partial               | Relative default case checked                     | Absolute or normalized-equivalent paths are not resolved                                |
| Malicious filename in Markdown          | None                                                                                   | No                    | No                                                | Raw path can disturb frontmatter, headings, or inline code                              |
| Malicious filename in JSON              | JSON control and quote escaping                                                        | Yes                   | No dedicated filename fixture                     | UTF-8 validity and normalization are not validated                                      |

The publication scheme must not be described as universally atomic. It provides staged replacement and rollback for managed artifacts, with tested preservation before publication and structurally attempted recovery during publication.

## Top-level declarations and entry points

| Declaration                    | Kind                  | Purpose                                                    | Inputs                                    | Output or effect                              | Ownership or lifetime                        |
| ------------------------------ | --------------------- | ---------------------------------------------------------- | ----------------------------------------- | --------------------------------------------- | -------------------------------------------- |
| `std`                          | Imported module       | Zig standard-library namespace                             | Compile-time import                       | Provides all runtime facilities               | Static                                       |
| `Io`                           | Type alias            | Short name for `std.Io`                                    | `std.Io`                                  | Type alias                                    | Static                                       |
| `format_id`                    | Public constant       | Catalog format identifier                                  | None                                      | `"boris-source-rag"`                          | Static                                       |
| `schema_version`               | Public constant       | Catalog metadata schema number                             | None                                      | `1`                                           | Static                                       |
| `tool_version`                 | Public constant       | Tool version string                                        | None                                      | `"0.1.0"`                                     | Static                                       |
| `ExitCode`                     | Public enum           | Stable process exit values                                 | Enum member                               | Integer code via `int`                        | Static                                       |
| `Options`                      | Public struct         | Runtime export configuration                               | Parsed or programmatic values             | Controls discovery, output, and tests         | Borrowed path slices; value type             |
| `Options.includeBundles`       | Method                | Resolve bundle emission                                    | `Options`                                 | Boolean                                       | No allocation                                |
| `Options.includePerFileDocs`   | Method                | Resolve per-file emission                                  | `Options`                                 | Boolean                                       | No allocation                                |
| `Profile`                      | Public enum           | Input-scope selection                                      | CLI or programmatic value                 | `all`, `core`, `docs`, `tools`                | Static                                       |
| `PackBy`                       | Public enum           | Output segmentation selection                              | CLI or programmatic value                 | `none`, `tool`                                | Static                                       |
| `packByName`                   | Public function       | Serialize pack axis                                        | `PackBy`                                  | Static name slice                             | Static                                       |
| `parsePackBy`                  | Function              | Parse pack axis                                            | String                                    | `PackBy` or parse error                       | Borrowed input                               |
| `profileName`                  | Public function       | Serialize profile                                          | `Profile`                                 | Static name slice                             | Static                                       |
| `parseProfile`                 | Function              | Parse profile                                              | String                                    | `Profile` or parse error                      | Borrowed input                               |
| `ParseError`                   | Public error set      | CLI parse errors                                           | None                                      | `UnknownFlag`, `MissingValue`, `InvalidValue` | Static                                       |
| `default_scan_dirs`            | Public constant array | Default candidate directory names                          | None                                      | Scan configuration                            | Static                                       |
| `default_root_files`           | Public constant array | Explicit root-level file candidates                        | None                                      | Scan configuration                            | Static                                       |
| `skip_dir_names`               | Constant array        | Directory basename exclusions                              | Entry name                                | Skip decision                                 | Static                                       |
| `skip_top_level_dirs`          | Constant array        | Root-tree prefix exclusions                                | Relative path                             | Skip decision                                 | Static                                       |
| `scanDirsForProfile`           | Function              | Map profile to candidate dirs                              | `Profile`                                 | Static slice                                  | Static                                       |
| `skip_file_names`              | Constant array        | File basename exclusions                                   | Entry name                                | Skip decision                                 | Static                                       |
| `include_extensions`           | Constant array        | Included suffixes                                          | Path                                      | Inclusion decision                            | Static                                       |
| `CatalogEntry`                 | Struct                | In-memory catalog row                                      | Generated metadata                        | Serialized catalog entry                      | String slices borrow arena or static data    |
| `ExportStats`                  | Public struct         | Export counters and byte total                             | Export operations                         | Returned summary                              | Value type                                   |
| `parseOptions`                 | Public function       | Parse process-style argument list                          | Argument slices                           | `Options` or `ParseError`                     | Returned path slices borrow argument storage |
| `printUsage`                   | Function              | Emit CLI help                                              | None                                      | Writes diagnostic output                      | No retained ownership                        |
| `isSkippedDirName`             | Public function       | Match directory exclusion                                  | Basename                                  | Boolean                                       | No allocation                                |
| `isSkippedFileName`            | Public function       | Match file exclusion                                       | Basename                                  | Boolean                                       | No allocation                                |
| `hasIncludedExtension`         | Public function       | Match extension or special name                            | Path                                      | Boolean                                       | No allocation                                |
| `langFromPath`                 | Public function       | Map extension to fence language                            | Path                                      | Static language slice                         | Static                                       |
| `ragPathForSource`             | Public function       | Build generated per-file path                              | Allocator, source path                    | Allocated path                                | Allocator-owned                              |
| `ragIdForSource`               | Public function       | Build retrieval ID                                         | Allocator, source path                    | Allocated ID                                  | Allocator-owned                              |
| `maxBacktickRun`               | Public function       | Measure fence-conflicting runs                             | Source body                               | Maximum run length                            | No allocation                                |
| `fenceLenFor`                  | Public function       | Select safe Markdown fence length                          | Source body                               | Fence length                                  | No allocation                                |
| `looksBinary`                  | Public function       | Detect NUL in initial body window                          | Source bytes                              | Boolean                                       | No allocation                                |
| `jsonEscapeAppend`             | Function              | Append JSON string content safely                          | Output buffer, allocator, bytes           | Mutates buffer                                | Buffer-owned                                 |
| `pathExists`                   | Function              | Probe file or directory existence                          | I/O context, directory, path              | Boolean                                       | Temporary handles closed locally             |
| `isUnderPrefix`                | Function              | Compare slash-separated path prefix                        | Relative path, prefix                     | Boolean                                       | No allocation                                |
| `isUnderOutDir`                | Function              | Apply output-prefix exclusion                              | Relative path, output path                | Boolean                                       | No allocation                                |
| `isSkippedTopLevelTree`        | Function              | Apply root-tree exclusions                                 | Relative path                             | Boolean                                       | No allocation                                |
| `collectUnderDir`              | Function              | Recursively collect candidates                             | Directories, allocators, prefixes         | Appends retained relative paths               | Paths retained in arena; list storage in GPA |
| `collectSourcePaths`           | Function              | Collect, sort, and deduplicate scan paths                  | Root, profile, output exclusion           | GPA-owned slice of arena-owned strings        | Caller frees slice; arena frees strings      |
| `readFileAlloc`                | Function              | Read entire file                                           | Directory, path, allocator                | Allocated byte buffer                         | Caller-owned                                 |
| `ensureParent`                 | Function              | Create parent directories                                  | Output root, generated path               | Filesystem mutation                           | No retained handle                           |
| `writeBytes`                   | Function              | Write one complete generated file                          | Output root, relative path, bytes         | Filesystem mutation                           | Caller owns input bytes                      |
| `managed_root_file_names`      | Constant array        | Declare owned root filenames                               | None                                      | Publication ownership set                     | Static                                       |
| `managed_tree_names`           | Constant array        | Declare owned tree names                                   | None                                      | Publication ownership set                     | Static                                       |
| `approxTokensFromBytes`        | Public function       | Apply upload-planning heuristic                            | Byte count                                | Integer floor of bytes divided by four        | No allocation                                |
| `fileByteSize`                 | Function              | Read generated file size                                   | Directory and relative path               | `usize` size                                  | No allocation                                |
| `isManagedBundleFileName`      | Function              | Recognize owned bundle names                               | Basename                                  | Boolean                                       | No allocation                                |
| `collectManagedBundleNames`    | Function              | Enumerate recognized bundles                               | Output directory                          | GPA-owned names and slice                     | Caller frees through helper                  |
| `freeManagedBundleNames`       | Function              | Release bundle-name collection                             | Allocator and names                       | Frees names and slice                         | Consumes allocation                          |
| `deleteManagedBundleFiles`     | Function              | Delete recognized bundles                                  | Output directory                          | Filesystem mutation                           | Temporary list freed locally                 |
| `deleteManagedFiles`           | Function              | Remove all managed artifacts                               | Output directory                          | Filesystem mutation                           | No retained ownership                        |
| `removeTreeIfPresent`          | Function              | Delete a tree when present                                 | Directory and path                        | Filesystem mutation                           | Temporary handle closed                      |
| `moveIfPresent`                | Function              | Rename one optional path                                   | Source dir, path, target dir              | Move and presence boolean                     | Filesystem owns result                       |
| `moveManagedBundleFiles`       | Function              | Move all recognized bundles                                | Source and target dirs                    | Filesystem mutation                           | Temporary names freed                        |
| `restorePreviousManagedCorpus` | Function              | Restore recovery artifacts                                 | Recovery and output dirs                  | Filesystem mutation                           | Moves ownership back to output               |
| `moveManagedCorpus`            | Function              | Move managed artifacts between dirs                        | Source and target dirs                    | Filesystem mutation                           | Moves filesystem entries                     |
| `publishManagedCorpus`         | Function              | Replace managed output through stage and recovery dirs     | Stage path, output path                   | Published corpus or error                     | Owns temporary handles and path string       |
| `log`                          | Function              | Emit progress unless quiet                                 | Options and format args                   | Diagnostic output                             | No ownership                                 |
| `renderSourceDocument`         | Function              | Render one source retrieval document                       | Metadata and source body                  | GPA-owned Markdown bytes                      | Caller frees                                 |
| `PackedSource`                 | Struct                | Retain accepted source for bundles                         | Metadata and owned body                   | In-memory bundle input                        | Body is GPA-owned                            |
| `BundleKind`                   | Enum                  | Classify source, docs, or content bundles                  | Source path                               | Bundle category                               | Static                                       |
| `bundleKindForPath`            | Function              | Classify by path prefix                                    | Source path                               | `BundleKind`                                  | No allocation                                |
| `bundleKindName`               | Function              | Serialize bundle kind                                      | `BundleKind`                              | Static name                                   | Static                                       |
| `bundleByteCount`              | Function              | Sum original body sizes                                    | Packed sources                            | Byte total                                    | No allocation                                |
| `packs_dir_name`               | Constant              | Managed pack-tree name                                     | None                                      | `"packs"`                                     | Static                                       |
| `core_pack_name`               | Constant              | Core pack name                                             | None                                      | `"core"`                                      | Static                                       |
| `docs_pack_name`               | Constant              | Docs pack name                                             | None                                      | `"docs"`                                      | Static                                       |
| `tooling_pack_name`            | Constant              | Shared tooling pack name                                   | None                                      | `"tooling"`                                   | Static                                       |
| `tool_pack_prefix`             | Constant              | Dynamic tool-pack prefix                                   | None                                      | `"tools-"`                                    | Static                                       |
| `topLevelSegment`              | Function              | Extract leading source-path segment                        | Source path                               | Borrowed subslice                             | Borrows input                                |
| `segmentInProfileScope`        | Function              | Check profile membership                                   | Segment and profile                       | Boolean                                       | No allocation                                |
| `packNameForPath`              | Function              | Assign one path to one pack                                | Arena and source path                     | Static or arena-owned pack name               | Arena-owned when dynamic                     |
| `Pack`                         | Struct                | Pack name and path list                                    | Partitioning                              | In-memory group                               | List storage GPA-owned; paths borrowed       |
| `partitionPacks`               | Function              | Group paths and sort packs                                 | Sorted paths                              | GPA-owned pack slice                          | Caller releases with `freePacks`             |
| `freePacks`                    | Function              | Release pack list storage                                  | Allocator and packs                       | Frees arrays                                  | Consumes allocation                          |
| `packPurpose`                  | Function              | Generate router description                                | Arena and pack name                       | Static or arena-owned string                  | Arena lifetime                               |
| `packQuestions`                | Function              | Generate router question summary                           | Arena and pack name                       | Static or arena-owned string                  | Arena lifetime                               |
| `PackSummary`                  | Struct                | Root-router pack statistics                                | Exported pack results                     | Router row                                    | Borrowed pack name                           |
| `BundlePart`                   | Struct                | Describe one generated part                                | Kind, file name, source slice             | Manifest and output metadata                  | Filename GPA-owned; sources borrowed         |
| `PartitionRange`               | Struct                | Temporary bundle slice boundaries                          | Indexes and byte count                    | Internal partition range                      | Value type                                   |
| `bundlePrefix`                 | Function              | Map kind to filename prefix                                | Bundle kind                               | Static prefix                                 | Static                                       |
| `bundleFileName`               | Function              | Construct part filename                                    | Allocator, kind, indexes                  | Allocated filename                            | GPA-owned                                    |
| `partitionBundleFiles`         | Function              | Split sorted files into whole-file ranges                  | Kind, file slice, split target            | GPA-owned part slice and names                | Caller frees                                 |
| `renderBundle`                 | Function              | Render one combined Markdown part                          | Part metadata and packed sources          | GPA-owned Markdown bytes                      | Caller frees                                 |
| `exportBundle`                 | Function              | Write one rendered bundle                                  | Output dir and part data                  | Generated file                                | Temporary rendered buffer freed              |
| `exportBundles`                | Function              | Emit all three bundle categories                           | Accepted source arrays                    | Bundle files and appended part records        | Part filenames transferred to aggregate list |
| `exportCatalogMeta`            | Function              | Write format metadata                                      | Profile and split size                    | `catalog_meta.json`                           | Stack buffer                                 |
| `exportProfileManifest`        | Function              | Write selected-source manifest                             | Stats and packed paths                    | `profile_manifest.json`                       | Temporary GPA buffer                         |
| `exportPartManifest`           | Function              | Write bundle map                                           | Profile, options, parts                   | `part_manifest.json`                          | Temporary GPA buffer                         |
| `exportUploadManifest`         | Function              | Write bundles-only upload planner                          | Generated files and parts                 | `upload_manifest.json`                        | Temporary arrays and buffer                  |
| `exportCatalogJsonl`           | Function              | Write catalog rows                                         | Sorted entries                            | `catalog.jsonl`                               | Temporary GPA buffer                         |
| `exportIndex`                  | Function              | Write flat pack index                                      | Catalog, stats, options, parts            | `INDEX.md`                                    | Temporary GPA buffer                         |
| `exportUploadGuide`            | Function              | Write mode-specific upload prose                           | Options                                   | `UPLOAD-GUIDE.md`                             | Static concatenated text                     |
| `sortCatalog`                  | Function              | Sort rows by generated path                                | Mutable entries                           | In-place order mutation                       | Caller-owned list                            |
| `token_estimate_method`        | Constant              | Label pack-router token heuristic                          | None                                      | `"bytes/4"`                                   | Static                                       |
| `exportPackRouter`             | Function              | Write root router and pack manifest                        | Pack summaries and totals                 | Root `INDEX.md`, `pack_manifest.json`         | Temporary buffers; arena prose               |
| `exportCorpus`                 | Public function       | Coordinate discovery, staging, pack selection, publication | I/O, allocator, options                   | `ExportStats` and generated corpus            | Owns export arena, stage handle, path slice  |
| `exportPackTree`               | Function              | Emit one complete flat corpus tree                         | Root, output dir, selected paths, options | Pack-local artifacts and stats                | Manages catalog, bodies, part names          |
| `main`                         | Public function       | Process entry, CLI diagnostics, exit mapping               | `std.process.Init`                        | Process exit code                             | Uses process arena and GPA                   |
| `expectOutputFileEqual`        | Test helper           | Compare generated file with expected bytes                 | Directory, path, expected body            | Test assertion                                | Temporary actual buffer                      |
| `writeMiniSourceRagFixture`    | Test helper           | Build minimal flat fixture                                 | Temp root                                 | Fixture files                                 | Temp-directory lifetime                      |
| `writePackByToolFixture`       | Test helper           | Build representative pack fixture                          | Temp root and optional tool               | Fixture files                                 | Temp-directory lifetime                      |

## Ownership and lifetime model

`main` obtains a “cold” allocator from `init.arena` and uses it to materialize and copy argument slices. The `args_list` backing allocation is deinitialized before `main` returns. Parsed option path slices borrow argument storage or static defaults.

`exportCorpus` receives the process GPA and creates a dedicated `ArenaAllocator`. The arena owns:

* duplicated discovered path strings;
* generated `rag_id` and `rag_path` strings;
* dynamic pack names;
* generated router descriptions and questions;
* other short-lived strings deliberately retained for the export.

The GPA owns:

* the outer discovered-path slice;
* mutable `ArrayList` backing allocations;
* each fully read source buffer;
* each retained `PackedSource.body`;
* generated Markdown and JSON buffers;
* generated bundle filenames;
* pack arrays and pack-path list storage;
* stage and recovery path strings.

Discovered path slices in lists borrow arena memory. Catalog strings borrow arena strings, static strings, or accepted source paths. Catalog list deinitialization releases only list storage, not those borrowed strings.

Each source file is first read into a GPA-owned buffer. That buffer is freed at the end of the loop iteration. An accepted source is duplicated into a second GPA-owned buffer for bundle generation and retained until the complete pack tree has been emitted. This means the tool may hold the bodies of all accepted files in one pack simultaneously.

Bundle rendering is not streaming. A complete bundle is assembled in an `ArrayList(u8)` before being written. Catalogs, manifests, and indexes are also assembled fully in memory before one-shot writes.

`PackedSource.body` values are freed by the category-list cleanup blocks. Bundle part filenames are freed by the `bundle_parts` cleanup block. Part source slices borrow the packed-source arrays and must not outlive them.

Directory and file handles use local `defer` cleanup. The root, stage output directory, pack directories, source files, and publication directories are closed on normal or error return.

The stage tree is owned by the current export until publication. An `errdefer` attempts to remove it if `exportCorpus` returns before successful publication. The recovery tree temporarily owns the previous managed corpus during publication.

The visible tests use `std.testing.allocator`, which can detect leaks for exercised success paths. No systematic allocation-failure injection is present, so leak freedom on every intermediate allocation error is not demonstrated.

## Error and diagnostic behavior

Diagnostics use `std.log.err` for process-level failures and `std.debug.print` for usage and progress. Generated errors are not encoded as structured JSON diagnostics.

| Condition                                                 | Detection point                  | User-visible behavior                               | Exit behavior      | Partial output risk                                            |
| --------------------------------------------------------- | -------------------------------- | --------------------------------------------------- | ------------------ | -------------------------------------------------------------- |
| Process arguments unavailable                             | `main`, argument materialization | `failed to read process arguments`                  | `2`                | None                                                           |
| Allocation while preparing argument list                  | `main`                           | `out of memory parsing arguments`                   | `2`                | None                                                           |
| Unknown argument                                          | `parseOptions`, then `main` scan | Usually names the unknown argument, prints usage    | `2`                | None                                                           |
| Missing CLI value                                         | `parseOptions`                   | Generic missing-value message and usage             | `2`                | None                                                           |
| Invalid profile, pack axis, number, or option combination | `parseOptions`                   | Generic invalid-value message and usage             | `2`                | None                                                           |
| Missing or inaccessible root                              | `exportCorpus.openDir`           | `source-rag export failed: <error-name>`            | `3`                | Prior output unchanged                                         |
| Missing candidate scan directory                          | Discovery                        | Silently ignored                                    | Success possible   | Corpus omits absent tree                                       |
| Candidate directory fails to open after probe             | `collectSourcePaths`             | Silently skipped by `catch continue`                | Success possible   | Corpus may omit a tree                                         |
| Unreadable source file                                    | `exportPackTree`                 | Progress line `skip read`, unless quiet             | Success possible   | File omitted                                                   |
| Source exceeds `max_bytes`                                | `exportPackTree`                 | Progress line `skip large`, unless quiet            | Success possible   | File omitted                                                   |
| NUL found in first 8 KiB                                  | `exportPackTree`                 | Progress line `skip bin`, unless quiet              | Success possible   | File omitted                                                   |
| Source read allocation failure                            | Caught by generic read catch     | Logged as skipped rather than fatal                 | Success possible   | File omitted; OOM can be masked as skip                        |
| Per-file or bundle write failure                          | `writeBytes`                     | Final error name from `main`                        | `3`                | Stage only, before publication                                 |
| Serialization allocation failure                          | Export function                  | Final error name from `main`                        | `3`                | Stage only, before publication                                 |
| Stage creation or cleanup failure                         | `exportCorpus`                   | Final error name, except best-effort error cleanup  | `3`                | Prior output normally unchanged; stale stage may remain        |
| Moving previous managed output fails                      | `publishManagedCorpus`           | Final error name or `SourceRagPublishRestoreFailed` | `3`                | Recovery attempted; partial movement possible if restore fails |
| Installing staged output fails                            | `publishManagedCorpus`           | Final error name or `SourceRagPublishRestoreFailed` | `3`                | New artifacts deleted and previous restored when possible      |
| Recovery cleanup fails after successful install           | `publishManagedCorpus`           | Suppressed                                          | `0`                | Published corpus remains; recovery material may remain         |
| Test-injected staged write failure                        | `exportPackTree`                 | Programmatic error; process would print error name  | `3` through `main` | Prior output preserved in test                                 |
| Allocation failure outside source-file read               | Propagated                       | Final error name from `main`                        | `3`                | Depends on whether publication began                           |

A notable distinction is that all errors from `readFileAlloc`, including allocation failure, are handled as per-file skips. Other allocation failures are fatal.

Exact error-name strings depend on Zig errors propagated from the standard library. Only `SourceRagPublishRestoreFailed` and `TestInjectedStageWriteFailure` are explicitly named by this file.

## Relationships to other files

| Related file or subsystem                    | Relationship                                | Direction                               | Authority                                              |
| -------------------------------------------- | ------------------------------------------- | --------------------------------------- | ------------------------------------------------------ |
| Zig standard library                         | Imported implementation dependency          | `main.zig` imports `std`                | Executable implementation                              |
| `tools/source-rag/build.zig`                 | Expected standalone build integration       | Build file would compile or test target | Unavailable                                            |
| `tools/source-rag/build.zig.zon`             | Expected standalone package metadata        | Build metadata to tool                  | Unavailable                                            |
| Root `build.zig`                             | Claimed convenience step `source-rag`       | Root build to executable                | Unavailable                                            |
| Root `build.zig.zon`                         | Possible dependency and Zig-version context | Build metadata to project               | Unavailable                                            |
| Boris `src/`                                 | Candidate input evidence                    | Tool reads source files                 | Current source is authoritative; generated copy is not |
| `docs/`                                      | Candidate input evidence                    | Tool reads documentation                | Tracked docs outrank generated packaging               |
| `content/`                                   | Candidate input evidence                    | Tool reads product content              | Product inputs remain authoritative                    |
| `layouts/`                                   | Candidate input evidence                    | Tool reads templates                    | Source template remains authoritative                  |
| `scripts/`, `test/`, `fixtures/`, `SUPPORT/` | Candidate tooling evidence                  | Tool reads selected files               | Original files remain authoritative                    |
| Root guidance and build files                | Explicit input evidence                     | Tool reads selected names               | Original tracked files remain authoritative            |
| Product content RAG                          | Explicitly described as separate            | No implementation call visible          | Unavailable implementation                             |
| Context Bundles                              | Conceptually separate                       | No implementation call visible          | Unavailable                                            |
| Migration tools                              | May be scanned as files; not invoked        | Source files to generated corpus        | Migration implementation remains authoritative         |
| Generated `files/` tree                      | Per-source generated output                 | Tool writes                             | Disposable derivative                                  |
| Generated bundles                            | Duplicate-body convenience output           | Tool writes                             | Disposable derivative                                  |
| Generated catalogs and manifests             | Generated inventory and routing             | Tool writes                             | Authoritative only for that generated corpus           |
| Inline tests in `main.zig`                   | Test declarations and synthetic fixtures    | Same file tests implementation          | Strong local evidence, execution unverified            |
| README and changelog files                   | Expected documentation/history              | Would describe tool                     | Unavailable                                            |
| Ignore rules                                 | Expected generated-output tracking policy   | Repository configuration                | Unavailable                                            |
| LLM or review workflow                       | Consumer workflow                           | Reads generated corpus                  | Consumer behavior is outside this file                 |

No imported implementation module exists beyond `std`. Therefore the target file appears to contain the complete visible tool implementation rather than delegating its major behavior to sibling Zig modules.

## Security and trust boundaries

### Repository paths

The scanner trusts the caller-selected root enough to enumerate it and read accepted files. Source paths are constructed from directory entry names, not supplied through a manifest. Direct path traversal through a source catalog is therefore not part of the normal flow.

The tool does not canonicalize the root or output path, assert that the output lies in or outside the root, reject traversal components, or reject absolute paths. It should not be treated as safely confined when run with attacker-controlled CLI paths.

### Arbitrary source bytes

Accepted source bodies are copied as opaque bytes into Markdown. The only content classification is:

* extension or special basename;
* original byte count;
* NUL detection in the first 8192 bytes;
* maximum length check after reading.

The tool does not validate UTF-8. It can package nontextual bytes that contain no early NUL, and it can miss a NUL occurring after the inspected prefix.

### Markdown fence safety

Dynamic fence length prevents backtick runs in the source body from closing the body’s code fence. This is implemented structurally and unit tested.

The mechanism does not protect raw frontmatter values or headings. A repository filename containing newlines, backticks, YAML punctuation, or Markdown syntax could alter the generated document structure.

### Embedded frontmatter and delimiters

Frontmatter present inside a source file remains inside its code fence and is not interpreted by the exporter. Bundle documents contain nested rendered source documents, including their frontmatter, but the nested source body remains fenced.

Generated bundle section headings and metadata interpolate source paths without escaping. Consumers should not treat generated Markdown as safe executable input.

### JSON safety

Machine-readable path and title fields use explicit JSON escaping for control bytes, quotes, and backslashes. No validation ensures that copied bytes form valid UTF-8 JSON strings on every platform.

### Symlinks

Recursive discovery processes only entries reported as `.directory` or `.file`. Explicit symlink entries appear to be ignored rather than followed, but the file does not state or test a symlink policy. Opening `--root` and `--out` may still traverse symlinks through operating-system path resolution.

### Output overwrite

The output root is never wholesale deleted. Managed filenames and trees are intentionally overwritten or retired. A preexisting caller-owned file named `INDEX.md`, `catalog.jsonl`, `pack_manifest.json`, or matching a managed bundle pattern is considered exporter-owned and may be moved or deleted.

### Resource exhaustion

The tool is not allocation-bounded or streaming:

* each candidate file is read with an unlimited read before `max_bytes` is checked;
* all accepted source bodies for a pack are retained;
* complete bundles, indexes, and manifests are assembled in memory;
* no total byte, file-count, path-length, or output-size limit exists.

A large or adversarial repository can consume substantial memory, disk space, and processing time.

### Terminal output

Source paths and error names are printed through formatting functions without terminal-control sanitization. A malicious filename containing terminal control bytes could affect progress output.

### Network boundary

No network, HTTP, socket, DNS, upload, model, or subprocess API appears in the target source. The implementation is structurally network-free and subprocess-free within this file. This does not prove what an unavailable wrapper or build step might do before or after invoking it.

The tool should not be described as safe to run on an untrusted repository merely because it emits Markdown. Resource use, filenames, output placement, filesystem behavior, and downstream Markdown handling remain trust boundaries.

## Evidence limitations

The analysis had complete access to the supplied `tools/source-rag/main.zig`, but not to the surrounding repository.

Unavailable evidence included:

* `tools/source-rag/build.zig`;
* `tools/source-rag/build.zig.zon`;
* `tools/source-rag/README.md`;
* `tools/source-rag/CHANGELOG.md`;
* root `build.zig`;
* root `build.zig.zon`;
* `AGENTS.md`;
* `docs/STATUS.md`;
* root changelog history;
* upload or usage guides outside generated strings in this file;
* Git ignore rules;
* tracked generated output;
* external fixtures or golden outputs;
* CI configuration;
* call sites or imports;
* product content-RAG implementation;
* Context Bundle implementation;
* documentation-observatory material;
* migration-tool integration.

The complete reporting requirements were supplied separately and explicitly require uncertainty where repository evidence is unavailable.

The environment did not contain a Zig compiler. Inline tests were inspected completely but not executed. Compile compatibility, passing status, allocator-test results, and process-level exit behavior therefore remain unconfirmed.

Claims about command names, Zig 0.16+, and root `source-rag` integration come from module comments, help text, or generated upload-guide text. They are source-authored documentation, not verified build declarations.

Claims about deterministic ordering, file ownership, serialization, and failure flow are inferred directly from implementation control flow. Byte-for-byte behavior is additionally asserted by tests, but only for synthetic fixtures and an unverified host platform.

No generated output was needed to understand serialization because the producer code and tests were available. Consequently, no example artifact has been promoted above its producer.

Explicitly versioned formats are limited to:

* `catalog_meta.json`;
* `pack_manifest.json`.

Other manifests and Markdown structures lack explicit schema versions. No compatibility parser or older-output migration behavior exists in the target file.

The most uncertain areas are:

* actual build and install wiring;
* product reverse linkage;
* standalone build support;
* cross-platform behavior;
* symlink semantics;
* publication rollback under real rename failures;
* generated-output tracking policy;
* current passing status of the tests.

## Final source assessment

`tools/source-rag/main.zig` is the complete visible implementation and process entry point for a standalone source-code corpus exporter. It performs deterministic candidate discovery, mechanical filtering, per-file Markdown wrapping, machine catalog construction, whole-file bundle partitioning, optional per-tool pack generation, upload planning, and staged publication of a managed output set.

Its strongest supported guarantees are local and concrete:

* accepted source paths are sorted and deduplicated;
* catalog entries and packs have deterministic order;
* bundle parts preserve whole files;
* oversized single sources are not split;
* generated data contains no timestamps or random identifiers;
* fixed output ownership prevents successful regeneration from leaving stale managed files;
* unrelated output siblings survive successful publication;
* a failure injected during staging leaves the previous published corpus untouched;
* representative repeated runs are asserted byte-identical.

Its weakest boundaries are build integration, cross-platform behavior, path canonicalization, malicious filenames, resource limits, symlink semantics, and failure during publication rollback. The implementation attempts restoration, but does not prove that every failure preserves a previous valid corpus.

The file is structurally separated from Boris product runtime through its dedicated `main`, its standalone CLI model, and its lack of Boris module imports. Exact reverse linkage and root build exposure cannot be confirmed without the unavailable build and call-site evidence.

The available source evidence is unusually strong for internal behavior because implementation and substantial inline tests reside in one file. Confidence is lower for repository architecture outside that file because the expected build, documentation, status, changelog, ignore, and CI evidence was unavailable, and the test suite could not be executed.

The most important unresolved question is the actual build and release boundary: whether current root and standalone build declarations compile this file only as an auxiliary executable, how its tests are invoked, and whether any Boris product artifact imports or depends on it.

<!-- BORIS-SOURCE-DOC END path="tools/source-rag/main.zig" -->
