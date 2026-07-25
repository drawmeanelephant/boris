---
title: "`tools/migration-lab/notion.zig` surface and execution"
id: docs/tools/migration-lab/notion/surface-and-execution
parent: docs/tools/migration-lab/notion
status: draft
tags: [boris, zig, tools, surface, migration-lab, notion]
---

# `tools/migration-lab/notion.zig` surface and execution

## CLI surface

`notion.zig` itself implements no CLI parsing. The CLI is handled entirely by `main.zig`. The Notion-relevant CLI arguments are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode notion` (or `notion-export`, `md-csv`) | No (implied by `--export`) | `astro` | `notion`, `notion-export`, `md-csv` | Selects Notion mode | `InvalidValue` → usage error, exit 2 |
| `--export <dir>` or `--export=<dir>` | Yes for notion mode | none | Any directory path | Sets `exportdir`; implies `--mode notion` | Missing or empty → `MissingValue`, exit 2 |
| `--out <dir>` or `--out=<dir>` | No | `migration-report` | Any directory path | Sets output directory | Missing value → `MissingValue`, exit 2; must differ from `--export` |
| `-q` / `--quiet` | No | false | (flag) | Suppresses progress output | N/A |
| `-h` / `--help` | No | false | (flag) | Prints usage, exits 0 | N/A |

**Guard enforced by `main.zig`:** If `exportdir == outdir` (string equality), exits with code 2 and an error message before calling `notion.run`.

**Exit codes:**

- 0: success
- 2: usage error (bad CLI, missing required argument, `--out == --export`)
- 3: IO error (runtime failure returned from `notion.run`)

Exact exit codes are directly supported by the `ExitCode` enum in `main.zig` with documented values `success=0`, `usage=2`, `ioerror=3`.

***

## Inputs and discovery model

`notion.zig` walks the export directory recursively, skipping a fixed set of directory names. The skip list is declared as a constant and covers standard tooling and VCS directories.

**Directory skip policy (`skipdirnames`):**
`.git`, `.hg`, `.svn`, `node_modules`, `dist`, `.output`, `.vercel`, `.netlify`, `zig-out`, `zig-cache`, `.zig-cache`, `.trash`, `.DS_Store`, `.notion`, `__MACOSX`

Additionally, any directory whose name begins with `.` and is not already covered by the above list is skipped (hidden tooling directories).

**Page file identification (`isMarkdownPage`):**
Files ending `.md` or `.mdx` (case-insensitive). Explicitly excluded: `README.md` and `README.mdx` at any depth (these are considered fixture tooling, not Notion pages).

**CSV database identification (`isCsvDatabase`):**
Files ending `.csv` (case-insensitive). These are inventoried as `unsupporteditems` with class `humanreview`; their content is not parsed or converted.

**Notion page-ID stripping (`stripNotionPageId`):**
Each path segment (folder name or file basename stem) is inspected. If the last 32 characters of the stem are all hex digits (`[0-9a-fA-F]`), and the stem is at least 33 characters long, the 32-hex suffix and the preceding space/separator are removed to yield the display title. Single-segment stems with no ID are preserved as-is.

**Entity-ID derivation (`pathToEntityId`, `sanitizeEntityId`):**
After ID stripping, the cleaned title segments are sanitized into Boris entity IDs: spaces and underscores become `-`; non-ASCII, non-alphanumeric, non-`.`/`-` characters are dropped; leading/trailing `-` are trimmed; consecutive `-` are collapsed. The maximum entity ID length is 255 bytes. Empty results fall back to `untitled`. The sanitizer is available in both a buffer form (`sanitizeEntityIdBuf`) and an allocating form (`sanitizeEntityIdAlloc`).

**Symlink handling:** Not explicitly documented in the source evidence examined; behavior uncertain for symlinks within the export tree.

**Path normalization (`normalizeRelPathAlloc`):** `..` path segments are rejected with `error.IllegalSegment`; `.` segments and empty segments are dropped; leading `./` is stripped. Paths that normalize to empty return `error.EmptyPath`.

### Input discovery table

| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Markdown/MDX pages | Recursive walk, `.md`/`.mdx` extension, case-insensitive | Yes | `README.md`, `README.mdx`; dirs in `skipdirnames`; hidden dirs | `isMarkdownPage`, `isSkippedDirName` in source |
| CSV database files | Recursive walk, `.csv` extension | Yes (as `unsupporteditems`) | Same dir exclusions | `isCsvDatabase` in source |
| Local attachments/media | Resolved from page link targets pointing to non-Markdown files | Only when referenced by a page | Same dir exclusions | Link-rewrite logic in source |
| Export root itself | `RunOptions.exportdir`, opened via `Io.Dir.cwd.openDir` | Required | Must differ from `outdir` | `main.zig` guard, `run` implementation |


***

## Output artifact model

All outputs are written under `RunOptions.outdir`. The output directory is created if it does not exist.

### Output artifacts

| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/<entity-id>.md` | Markdown with Boris frontmatter + provenance comment | Tool-owned, generated | Lexicographic by entity ID (inferred from sorted discovery) | Boris compiler (after human review) | Not versioned; format changes with implementation |
| `media/<relative-path>` | Binary bytes (unchanged from export) | Tool-owned, generated | Mirrors export structure | Boris asset pipeline (after human review) | Byte-identical to source |
| `report.json` | JSON, format `boris-notion-migration-lab`, `schemaVersion: 1` | Tool-owned, generated | Fixed field order per schema | Human review, tooling | Schema version 1; stability uncertain beyond schemaVersion field |
| `REPORT.md` | Markdown, human-readable summary | Tool-owned, generated | N/A | Human review | Not versioned |
| `mediamanifest.json` | JSON, per-entry inventory | Tool-owned, generated | Deterministic (source-path ordered) | Provenance tracking | Not versioned beyond format identifier |

**Re-run behavior:** Not explicitly tested for stale-output cleanup in the examined evidence for the notion mode specifically (the WordPress mode has an explicit stale-cleanup test; the notion mode's behavior on re-run into the same `--out` is uncertain from available evidence).

**Canonical machine records:** `report.json`, `mediamanifest.json`
**Human convenience:** `REPORT.md`
**Generated and disposable:** All outputs under `--out` (tool-owned, never tracked)
**Required for a minimally useful result:** `content/` tree, `report.json`
**Optional:** `REPORT.md`, `mediamanifest.json` (informational)

### `report.json` top-level fields (schema 1)

From the inline test assertions and README schema note:
`format`, `schemaVersion`, `toolVersion`, `sourceExport`, `summary`, `pages`, `links`, `hazards`, `media`, `unsupportedItems`, `humanReview`

Summary sub-fields include: `resolved`, `ambiguous`, `unresolved`, `databaseCsv`, `relationOrRollup` (or `syncedBlock`).

***

## Serialization and schema behavior

`notion.zig` serializes all machine-readable output using hand-written JSON construction (no `std.json` serialization framework — consistent with the rest of the `tools/migration-lab/` codebase). Field ordering is fixed by the order of `appendSlice` calls in the report-emission functions.

**Format identifier:** `boris-notion-migration-lab`
**Schema version:** `pub const schemaVersion: u32 = 1`
**Tool version:** `pub const toolVersion = "0.1.0"` (a string constant, not a semantic version integer)

Path representations in JSON use forward-slash separators (POSIX-style) as constructed by `normalizeRelPathAlloc`.

Byte counts appear in `mediamanifest.json` entries. SHA-256 digests do not appear to be computed for Notion media entries in the same way as in `themearchaeology.zig` — this is uncertain from available evidence.

JSON string escaping is handled by the shared `appendJson` helper (present in peer modules; likely shared or duplicated in `notion.zig`), which escapes `"`, `\`, control characters, and bytes below `0x20` using `\uXXXX` encoding.

Newline policy: output files end with a newline appended if the last byte is not already `\n` (a pattern visible in page-emission logic).

### Machine format table

| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` | `boris-notion-migration-lab` / schemaVersion 1 | `notion.zig` emit functions | Fixed field order | Inline tests check field presence by substring; no schema validator |
| `mediamanifest.json` | No explicit schema identifier found | `notion.zig` | Source-path ordered | Inline tests check field presence by substring |
| Per-page `.md` files | Boris closed frontmatter (no version field) | `notion.zig` | N/A per file | Inline tests check key presence |


***

## Determinism and reproducibility

The tool is explicitly described in the module header as emitting a "deterministic manifest." The inline tests directly verify byte-identical repeated runs for `report.json`, `REPORT.md`, and `mediamanifest.json` by running the tool twice into separate output directories and comparing the files with `std.testing.expectEqualStrings`.

### Determinism evidence table

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable discovery order | Directory walk with sorted or lexicographic ordering (exact sort mechanism uncertain — depends on `Io.Dir` walk implementation and how results are collected) | Partial coverage | Filesystem enumeration order may vary on some platforms if not explicitly sorted |
| Stable output field order | Fixed-order JSON append calls | Structurally checked | No independent schema enforcer |
| Byte-identical repeated runs | Direct test: run twice, compare `report.json`, `REPORT.md`, `mediamanifest.json` | Directly demonstrated | Cross-platform identity not tested; absolute paths in output uncertain |
| No timestamps in output body | Not observed in field list; module comment states "fixed field order no host timestamps in report bodies" | Documented contract | Not independently verified by test |
| Path separators | POSIX `/` via `normalizeRelPathAlloc` | Structurally checked | Windows path handling uncertain |
| Entity-ID collision deduplication | Deterministic suffix strategy implied by README description; direct evidence in `notion.zig` for `sanitizeEntityIdBuf` | Partial coverage | Collision suffix behavior for notion specifically not directly tested in available fixture evidence |


***

## Filesystem and path safety

### Path safety table

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output inside export tree | `main.zig` string-equality guard (`exportdir == outdir`) | Enforced in caller (`main.zig`) | Not tested at module level | Subdirectory relationship (one contains the other as a prefix) not guarded at tool level |
| Path traversal in export links | `normalizeRelPathAlloc` rejects `..` segments with `error.IllegalSegment` | Yes, structurally | Directly tested (unit test for `normalizeRelPath`) | Applied to link resolution; direct filesystem writes use path construction — containment relies on convention |
| Absolute paths in link targets | `resolveRelativePath` strips leading `/` and treats as root-relative within export | Structurally handled | Uncertain — not directly tested in available evidence |  |
| Percent-encoded traversal | `percentDecodeAlloc` decodes first; resolved path then passes through `normalizeRelPathAlloc` | Structurally chained | Tested for percent-decode correctness (`percentDecodeAlloc spaces and hex`) | Traversal after decode covered by `normalizeRelPath`; end-to-end path safety test not directly evidenced |
| Symlink traversal in export | `isSymlink` check pattern present in peer modules; presence and behavior in `notion.zig` specifically is uncertain | Uncertain | Uncertain | Symlink escape behavior not directly tested for notion mode |
| Output overwrite on re-run | Prior output replaced on re-run; stale cleanup for notion mode uncertain | Uncertain (not tested for notion) | Not evidenced | Stale media files from a prior run may survive if re-run with changed export |
| Output-root containment for writes | Path construction under `outdir` prefix | Convention-based | Not independently tested | Relies on correct path construction, not a filesystem jail |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `formatId` | `const []const u8` | Identifies the output format | — | `"boris-notion-migration-lab"` | Static, comptime |
| `schemaVersion` | `const u32 = 1` | Schema version for machine outputs | — | `1` | Static, comptime |
| `toolVersion` | `const []const u8` | Tool version string | — | `"0.1.0"` | Static, comptime |
| `maxEntityIdBytes` | `const usize = 255` | Maximum byte length for a Boris entity ID | — | Bound used by sanitizer | Static, comptime |
| `RunOptions` | `struct` | Configuration passed from `main.zig` | — | Typed options | Borrowed from caller; no owned allocation |
| `ConversionClass` | `enum` | Classifies each page conversion outcome | — | `exact`, `transformed`, `unsupported`, `humanReview` | Per-record, arena-owned |
| `LinkStatus` | `enum` | Classifies each link rewrite outcome | — | `resolved`, `unresolved`, `ambiguous`, `externalSkipped`, `skippedFence`, `unsupportedEmbed` | Per-record, arena-owned |
| `skipDirNames` | `const []const []const u8` | Directory names to skip during walk | — | Skip list | Static |
| `isSkippedDirName` | `fn` | Tests whether a dir name should be skipped | `name: []const u8` | `bool` | No allocation |
| `isMarkdownPage` | `fn` | Tests whether a path is a Notion page file | `path: []const u8` | `bool` | No allocation |
| `isCsvDatabase` | `fn` | Tests whether a path is a Notion CSV database | `path: []const u8` | `bool` | No allocation |
| `isNotionPageId` | `fn` | Tests whether a string is a 32-hex Notion ID | `s: []const u8` | `bool` | No allocation |
| `stripNotionPageId` | `fn` | Splits a Notion export stem into title + optional 32-hex ID | `stem: []const u8` | `struct { title, pageId }` — slices of input | No allocation; slices borrow input |
| `normalizeRelPathAlloc` | `fn` | Normalizes a relative path; rejects `..` | `allocator, path` | `![]u8` owned slice or `error.IllegalSegment` / `error.EmptyPath` | Caller owns result |
| `pathToEntityId` (notion) | `fn` | Maps an export-relative page path to a Boris entity ID | `allocator, exportRel` | `![]u8` | Caller owns result |
| `sanitizeEntityIdBuf` | `fn` | Non-allocating entity-ID sanitizer into a caller-supplied buffer | `buf, stem` | `?[]const u8` slice of `buf` | Borrow of `buf` |
| `sanitizeEntityIdAlloc` | `fn` | Allocating entity-ID sanitizer | `allocator, stem` | `![]u8` | Caller owns result |
| `basenameOf` | `fn` | Returns the basename of a path | `path` | Slice of input | Borrowed |
| `basenameStem` | `fn` | Returns the basename without `.md`/`.mdx` | `path` | Slice of input | Borrowed |
| `relativeLink` | `fn` | Constructs a relative `../` link from a content file to a media file | `allocator, fromFile, toFile` | `![]u8` | Caller owns result |
| `percentDecodeAlloc` | `fn` | Percent-decodes a URL path | `allocator, s` | `![]u8` | Caller owns result |
| `resolveRelativePath` | `fn` | Resolves a relative href from a page file without leaving export root | `allocator, fromFile, target` | `![]u8` or error | Caller owns result |
| `borisKeys` | `const []const []const u8` | Closed Boris frontmatter key set | — | `id`, `title`, `parent`, `status`, `tags` | Static |
| `FrontmatterInfo` | `struct` | Parsed frontmatter fields | — | Present flag, body offset, field values, unknown keys, notes | Per-parse, arena-owned |
| `parseFrontmatterLite` | `fn` | Parses YAML-lite frontmatter compatible with Boris closed grammar | `allocator, source` | `!FrontmatterInfo` | Caller owns result slices |
| `PageEntry` | `struct` | Resolution-index record for a discovered page | — | Export path, entity ID, output path, title basename, page ID, parent, depth | Arena-owned |
| `MediaEntry` | `struct` | Resolution-index record for a discovered media file | — | Export path, output path | Arena-owned |
| `Index` | `struct` | Resolution index for the entire export tree | `pages []PageEntry`, `media []MediaEntry` | Lookup methods `resolvePage`, `resolveMedia`, `collectAmbiguousPages` | Arena-owned lifetime |
| `run` | `pub fn` | Main entry point for notion mode; called by `main.zig` | `io Io`, `gpa Allocator`, `opts RunOptions` | `!void`; writes output tree | Process-scoped allocations freed on return; `gpa` used for all allocations |

For `run`:

- **Initialization:** Opens the export directory and creates the output directory.
- **Allocator setup:** Uses the GPA passed from `main.zig`; no process-level arena at the `run` boundary (individual sub-allocations use `gpa`).
- **Discovery:** Walks the export tree, builds page and media lists.
- **Processing:** For each page — parses frontmatter, strips IDs, derives entity ID, rewrites body links, copies media, builds conversion record.
- **Output:** Writes per-page `.md` files, `mediamanifest.json`, `report.json`, `REPORT.md`.
- **Progress:** Prints to stderr unless `opts.quiet`.
- **Cleanup:** Returns error on failure; partial output may exist on error (not cleaned up on failure — uncertain).
- **Exit behavior:** Returns `!void`; `main.zig` maps error to `ExitCode.ioerror` (exit 3).

***

## Ownership and lifetime model

- **GPA (general-purpose allocator):** Passed in from `main.zig`; all allocations within `run` and its callees use this allocator. No process-level arena at the `run` boundary.
- **Page and media lists:** Allocated with GPA during discovery walk; owned for the duration of `run`.
- **Path strings:** Produced by `pathToEntityId`, `normalizeRelPathAlloc`, `sanitizeEntityIdAlloc`, `resolveRelativePath`, `relativeLink`, `percentDecodeAlloc` — all return owned slices; caller frees.
- **File body slices:** Read into GPA-owned buffers per file; freed after processing.
- **FrontmatterInfo fields:** Arena-style ownership within `parseFrontmatterLite`; slices borrow from the source buffer or are duplicated into GPA.
- **Report buffers:** Accumulated in `std.ArrayList(u8)` backed by GPA; converted to owned slices for writing.
- **Cleanup on success:** Individual sub-allocations deferred or freed inline; GPA returned to caller.
- **Cleanup on failure:** Partial allocations from `errdefer` patterns are freed; output files partially written on IO failure are not cleaned up (uncertain — no explicit cleanup-on-error logic observed in available evidence).

Leak freedom is not claimed — no allocator validation or `std.testing.allocator` leak detection is evident in the notion-specific integration test (which uses `std.testing.allocator` only for inline unit tests, not the full `run` invocation which uses a separate GPA).

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Missing `--export` argument | `main.zig` mode dispatch | `log.err` + `printUsage` to stderr | Exit 2 | None |
| `--export == --out` | `main.zig` before `notion.run` | `log.err` message to stderr | Exit 2 | None |
| Export directory not found / unreadable | `notion.run` open call | Propagated as `!void`; `main.zig` logs `migration-lab notion failed: <errorName>` | Exit 3 | None (fails before writes) |
| Output directory creation failure | `notion.run` | Same propagation | Exit 3 | None or partial |
| Individual page unreadable | Within page loop | Behavior uncertain — may propagate or skip; not directly tested | Uncertain | Possible partial output |
| `..` segment in export link target | `normalizeRelPathAlloc` | Returns `error.IllegalSegment`; link left raw with review note | Continues (link flagged, not fatal) | Not an exit condition |
| Empty normalized path | `normalizeRelPathAlloc` | `error.EmptyPath`; handled in link resolution | Continues | Not an exit condition |
| Allocation failure | Any `try` expression | Propagated as `error.OutOfMemory` → exit 3 | Exit 3 | Partial output possible |
| Serialization failure | Report/manifest emit | Propagated as IO error → exit 3 | Exit 3 | Partial output possible |

All user-visible errors at the process level are plain stderr messages via `std.log.err`. There is no structured diagnostic format for runtime errors; structured diagnostics exist only within the output report files themselves (hazards, human-review queue).

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Caller; imports `notion.zig` as `const notion = @import("notion.zig")`; dispatches `notion.run` | Caller → module | `main.zig` owns CLI and process lifecycle |
| `tools/migration-lab/build.zig` | Build integration; compiles `notion.zig` as part of the `boris-migration-lab` executable | Build system → source | `build.zig` is authoritative for compilation |
| `tools/migration-lab/fixtures/mini-notion/` | Test fixture; used by integration and unit tests inside `notion.zig` | Module → fixture (read) | Fixture is input evidence |
| `tools/migration-lab/README.md` | Documentation; describes Notion mode inputs, outputs, safety rules, and quick-start commands | Documentation | README is documentation, not executable evidence |
| `docs/MIGRATION.md` | Author guide; describes human follow-up after migration-lab output | Documentation | Normative for human workflow, not implementation |
| `boris-source-*.md` (source-RAG packs) | Packed source in the source-RAG corpus; not a normative contract | Generated output | Lower authority than source |
| `tools/migration-lab/obsidian.zig`, `wordpress.zig`, etc. | Peer mode modules; share structural patterns and some helper conventions | Sibling | No import dependency in either direction |
| `src/` (Boris product compiler) | No relationship — not imported, not linked | None | N/A |


***

## Security and trust boundaries

**Input trust level:** The Notion export directory is treated as untrusted developer-supplied data. Path components from the export tree are normalized and sanitized before use. Links within page bodies are treated as untrusted strings.

**Path traversal:** `normalizeRelPathAlloc` rejects `..` segments. `resolveRelativePath` strips leading `/` treating it as root-relative. Percent-encoded traversal is mitigated by decoding before normalization. This chain is structurally implemented but not end-to-end tested for the notion mode specifically.

**Markdown fence safety:** Body text from Notion pages is not escaped when written into output `.md` files (it is reproduced as opaque bytes). A Notion page containing Markdown fences, frontmatter delimiters, or HTML that resembles Boris constructs will be copied verbatim. The tool does not attempt to neutralize adversarial fence content within page bodies.

**Embedded frontmatter:** Existing Notion frontmatter is parsed by `parseFrontmatterLite`. Unknown keys are dropped from the output and recorded in the review queue — they do not escape into live Boris frontmatter. Known Boris keys from the export are preserved only when compatible; incompatible frontmatter is flagged.

**Generated bundle delimiters:** Not applicable (the tool does not produce source-RAG bundles).

**Opaque byte copying:** Media files are copied as raw bytes without inspection or validation. A maliciously named media file could produce unexpected output paths if path sanitization is insufficient, but media paths are constructed from the entity-ID and media-path sanitization logic.

**Terminal output:** Progress messages are written to stderr via `std.log` / `std.debug.print`. Filenames from the export tree may appear in progress output; terminal escape sequences in filenames are not neutralized.

**Network exfiltration:** Absent — no network access of any kind is present in the implementation.

**Resource exhaustion:** Very large exports or very large individual files could exhaust memory. No explicit file-size limit or streaming read is evidenced. This is uncertain.

**Maliciously chosen filenames:** A Notion export file whose name contains characters that survive sanitization into an unexpected Boris entity ID could cause unexpected output file placement. The sanitizer drops non-ASCII and most punctuation, but the output path is not re-validated against a filesystem containment check.

**Assumptions imposed on the caller:** `main.zig` is responsible for the `exportdir != outdir` guard; `notion.run` does not re-check this.

***

## Evidence limitations

- `tools/migration-lab/build.zig` and `build.zig.zon` were not directly read; build declarations are inferred from README documentation and peer module patterns. Build option details (target, optimization) are uncertain.
- `tools/migration-lab/CHANGELOG.md` was not directly examined; version history and schema change record are uncertain.
- The full body of `notion.zig`'s `run` function and report-emission functions is available only through the packed source-RAG corpus representation, which strips some whitespace and comments. Certain fine details of the serialization and cleanup logic may be misread.
- Stale-output cleanup behavior for notion mode on re-run is not evidenced. (WordPress has an explicit test; notion does not in available evidence.)
- Symlink handling within the Notion export tree is not directly evidenced for this module.
- The exact mechanism for sorting discovered pages (filesystem walk order vs. explicit sort) is uncertain; determinism is demonstrated by test but the mechanism is not confirmed.
- SHA-256 hashing of media entries in `mediamanifest.json` for the notion mode is uncertain — the field is present in peer modules (theme-archaeology) but its presence in notion's media manifest is inferred, not confirmed.
- Allocation-failure behavior is not tested; `error.OutOfMemory` propagation is structurally present but not directly verified.
- The behavior on very large exports, deep directory trees, or page files with extremely long lines is unknown.
- `AGENTS.md` and `docs/STATUS.md` were not directly examined; any constraints documented there are not reflected in this dossier.

***

## Final source assessment

`tools/migration-lab/notion.zig` is a self-contained, medium-complexity developer-tool implementation module responsible for the complete Notion-export-to-Boris-candidate conversion pipeline. Its actual responsibility is: walk an unpacked Notion export tree, strip Notion page IDs, sanitize paths into Boris entity IDs, rewrite local links deterministically, copy media bytes, and emit a machine-readable report with a human review queue.

**Strongest supported guarantees:**

- No modification of the export tree (structurally enforced; directly tested)
- No network access (structurally enforced)
- Byte-identical repeated runs for machine outputs (directly tested)
- `..` path traversal rejection in link resolution (structurally enforced; unit tested)
- Strict output-only writes under `--out` (enforced by caller guard + path construction convention)

**Weakest or least-tested boundaries:**

- Stale-output cleanup on re-run (not tested for notion mode)
- Symlink escape within export tree (not evidenced)
- End-to-end path traversal via adversarial export content (partially covered by unit tests; no hostile notion fixture equivalent to `fixtures/hostile-instagram`)
- Allocation-failure behavior (not tested)
- Output-root prefix-containment (string equality guard only, not prefix guard)

**Separation from Boris product runtime:** Complete. No `src/` imports, not linked into `boris` binary, excluded from root `zig build test`.

**Quality of available evidence:** Good for core happy-path behavior and determinism; moderate for path-safety edge cases; weak for failure-path cleanup and symlink handling.

**Most important unresolved question:** Whether a re-run of the notion mode into the same `--out` directory correctly removes stale output from a prior run with a different export. If it does not, human reviewers could silently inherit orphaned pages or media from a previous migration attempt.
