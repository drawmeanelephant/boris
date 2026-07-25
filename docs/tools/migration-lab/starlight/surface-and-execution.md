---
title: "`tools/migration-lab/starlight.zig` surface and execution"
id: docs/tools/migration-lab/starlight/surface-and-execution
parent: docs/tools/migration-lab/starlight
status: draft
tags: [boris, zig, tools, surface, migration-lab, starlight]
---

# `tools/migration-lab/starlight.zig` surface and execution

## CLI surface

CLI parsing is implemented entirely in `main.zig`; `starlight.zig` exposes only its `run()` function accepting a `RunOptions` struct. The following flags are relevant to Starlight mode. All flags are parsed by `main.parseOptions()`.[^1_3]


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode starlight` (or `sl`, `evcc`) | No (can be inferred) | `astro` | `starlight`, `sl`, `evcc` | Activates Starlight mode | Unknown mode → `error.InvalidValue` → exit 2 |
| `--root <dir>` | Yes (for Starlight mode) | `.` | Any path | Starlight project root to scan read-only | Missing value → `error.MissingValue` → exit 2 |
| `--out <dir>` | No | `migration-report` | Any path | Output directory; must differ from `--root` | Same value as `--root` → explicit error message + exit 2 |
| `--locale <key>` | No | `en` | BCP-47-style tag (e.g. `en`) | Discovery key; selects `src/content/docs/<locale>/` when present | Missing value → exit 2; no i18n fallback logic |
| `--max-pages &lt;N>` | No | `40` | Positive integer | Hard cap on converted pages; synthetic trunks do not count | Non-integer → `error.InvalidValue` → exit 2 |
| `--boris <path>` | No | `null` | Path to Boris binary | Triggers optional compile verification; result written to `compilereport.json` | Binary not found → error recorded in `compilereport.json`; does not abort run |
| `--quiet` / `-q` | No | off | (flag) | Suppresses progress lines on stderr | N/A |
| `--help` / `-h` | No | off | (flag) | Prints usage and exits 0 | N/A |
| Unknown flag | — | — | — | `error.UnknownFlag` → stderr message + exit 2 | — |

**Exit codes:** 0 (success), 2 (usage/CLI error), 3 (IO error from `starlight.run()` propagating an error). Exact exit codes are directly evidenced by the `ExitCode` enum in `main.zig`.[^1_3]

**Help output:** Produced by `printUsage()` in `main.zig`. Includes Starlight-specific flags and their aliases. No separate `--help` handling in `starlight.zig` itself.

**Mutually incompatible options:** `--out` must differ from `--root`; enforced in `main` before calling `starlight.run()` with an explicit error message and exit 2.

***

## Inputs and discovery model

`starlight.zig` treats the source root as entirely read-only. Discovery begins by locating the content root, then collecting candidate Markdown files.[^1_2][^1_4]

**Content root discovery (`discoverContentRoot`):** Opens the source root and checks for `src/content/docs`. If `src/content/docs/<locale>/` exists and contains at least one Markdown file, that locale-directory shape is used. Otherwise, the root-locale shape (`src/content/docs/` itself) is used, skipping sibling first-level directories that look like locale codes (2-letter or `xx-yy` forms via `looksLikeLocaleDirName`). If neither yields a content root, `error.ContentRootNotFound` is returned.[^1_2]

**Candidate collection (`collectMarkdownFiles`):** Recursive filesystem walk collecting `.md` and `.mdx` files. Skips directories matched by `isSkipDir`: `.git`, `.hg`, `.svn`, `node_modules`, `.astro`, `dist`, `.vercel`, `.netlify`, `.output`, `zig-out`, `.zig-cache`, `zig-cache`.[^1_2]

**Candidate page filter (`isCandidatePage`):** Excludes files whose basename begins with `_` (underscore partials). No allowlist of preferred sections.[^1_2]

**Selection and `--max-pages`:** After discovery, paths are sorted lexicographically. Pages are selected in that order up to `maxpages`. Synthetic trunks created by the converter do not count toward this cap.[^1_4]

**Entity collision handling:** If two source paths produce the same entity ID (same route after index-collapse and locale-strip), the first in lexicographic order wins; others receive deterministic `-2`, `-3` suffixes. All collision rows are recorded in `unsupportedmanifest.json`.[^1_4]

**Public directory:** Used for resolving site-absolute image references (e.g., `/images/hero.png`) by looking up `public/images/hero.png` under the source root.[^1_2]


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| `.md` / `.mdx` files | Recursive walk from content root | Yes | `_` partials, skip-dirs | `collectMarkdownFiles`, `isCandidatePage` in source |
| Source frontmatter | Line-oriented parser (no full YAML) | Yes | None | `parseFrontmatterLite` in source |
| MDX import lines | `isImportLine` scan | Inventoried | Not converted | `extractImportPath` in source |
| `astro.config.*` | Text-scan for sidebar evidence | Yes (text-scan only) | No evaluation | README, `navflatten.json` output |
| `public/` directory | Checked for absolute image refs | When image is site-absolute | N/A | `sha256Hex`, `enrichAssetsWithHashes` in source |
| Sibling locale directories | Skipped via `looksLikeLocaleDirName` | Skipped | N/A | `discoverContentRoot` in source |
| Generated output directories | Skipped via `isSkipDir` | Skipped | `zig-out`, `dist`, etc. | `isSkipDir` in source |
| Symlinks | Not explicitly handled | Unknown | N/A | Not evidenced in source; uncertain |
| Files beyond `--max-pages` | Excluded after sorting | No | After cap | `maxpages` field in `RunOptions` |


***

## Output artifact model

All outputs are written under `--out`. The module does not write temporary files to any intermediate staging area; output is written directly to the destination paths. No cleanup of previous output is performed before writing; stale file deletion behavior is not evidenced in the source.[^1_4][^1_2]


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/<entity>.md` | Boris-candidate Markdown | Generator-owned | Lexicographic by entity ID | Human reviewer / Boris compiler | Not versioned; format ID embedded in provenance comment |
| `content/<entity>.assets/<file>` | Binary copy of source asset | Generator-owned | N/A | Boris compiler | Byte-identical to source |
| `routemap.json` | JSON object mapping source route → entity | Generator-owned | Sorted by route | Review workflows | Not versioned |
| `selectionmanifest.json` | JSON array of selection rows | Generator-owned | Sorted by source path | Review | Not versioned |
| `unsupportedmanifest.json` | JSON array of unsupported/collision items | Generator-owned | Sorted | Review | Not versioned |
| `assetsmanifest.json` | JSON array of asset entries with `exists`, `sha256hex`, `bytes` | Generator-owned | Sorted by source path | Review, Boris compile gate | Not versioned |
| `navflatten.json` | JSON object of sidebar/nav text-scan evidence | Generator-owned | N/A | Review | Not versioned |
| `provenancemanifest.json` | JSON array of raw source frontmatter blocks | Generator-owned | Sorted by source path | Review | Not versioned |
| `linkreview.json` | JSON array of link events | Generator-owned | Sorted by source entity, line | Review | Not versioned |
| `headingfragments.json` | JSON array of fragment inventory | Generator-owned | N/A | Review | Not versioned |
| `boundarymanifest.json` | JSON array of boundary items (preserved/stripped/manualreview) | Generator-owned | N/A | Review | Not versioned; byte-identity tested |
| `relationcandidates.json` | JSON array of relation candidate rows | Generator-owned | Sorted by entity, source line, value index, field, raw value | Review | Not versioned |
| `compilereport.json` | JSON object of Boris compile attempt result | Optional; only with `--boris` | N/A | Review | Not versioned |
| `report.json` | JSON summary of counts and decisions | Generator-owned | N/A | Review | Not versioned |
| `REPORT.md` | Human-readable Markdown summary | Generator-owned | N/A | Human reviewer | Not versioned |

**Canonical machine records:** `boundarymanifest.json`, `assetsmanifest.json`, `linkreview.json`, `selectionmanifest.json`, `relationcandidates.json`, `provenancemanifest.json`.

**Human convenience:** `REPORT.md`, `report.json`, `navflatten.json`.

**Required for minimally useful output:** `content/` Markdown tree + `selectionmanifest.json` + `linkreview.json` + `boundarymanifest.json`.

**Optional:** `compilereport.json` (only when `--boris` is supplied), `headingfragments.json`, `navflatten.json`.

No manifest format uses an explicit schema version field at the individual artifact level; the format identifier `boris-starlight-migration-lab` and `schemaVersion: 1` are declared as constants in `starlight.zig` (`pub const formatId` and `pub const schemaVersion`), but there is no evidence that these are embedded in every output file as a version header.[^1_2]

***

## Serialization and schema behavior

The module serializes all JSON outputs using Zig standard library JSON writers. No external JSON schema library is used.[^1_2]

**Format identifier:** `pub const formatId = "boris-starlight-migration-lab"` and `pub const schemaVersion: u32 = 1` and `pub const toolVersion = "0.3.1"` are declared at the top of `starlight.zig`. Whether these are embedded in every output file's content is not directly evidenced from the available source excerpts; the provenance comment in converted Markdown files embeds `formatId` and `toolVersion` via `emitPage`.[^1_2]

**Field ordering:** Determined by the order of `try buf.appendSlice()` calls in serialization functions such as `emitPage` and the JSON append helpers. This is structurally fixed per record type, not driven by a schema definition shared with a parser.

**Record ordering:** JSON arrays are sorted before emission. `collectRelationCandidates` explicitly calls `std.mem.sort` on the output slice with a deterministic comparator: `sourceentity` → `sourceline` → `valueindex` → `sourcefield` → `rawvalue`.[^1_2]

**Path representation:** Paths are stored as repository-relative strings using forward-slash separators as constructed by the allocation helpers (`outputPathFromEntity`, `routeFromEntity`). Platform separator behavior on Windows is not tested.

**Digest fields:** `assetsmanifest.json` includes `sha256hex` fields computed by `sha256Hex()` using `std.crypto.hash.sha2.Sha256`. The hex string is 64 lowercase hex characters. `enrichAssetsWithHashes` populates these fields by reading source asset bytes.[^1_2]

**Newline policy:** Output Markdown files use `\n` as constructed by string append operations. Cross-platform newline normalization is not evidenced.

**Empty arrays/bundles:** Not explicitly evidenced; behavior for zero-page runs (e.g., `error.ContentRootNotFound`) is to return an error before writing any output, not to write empty manifests.

**Parsing and emission sharing a schema:** No. Emission is inline string construction; there is no shared schema definition consumed by both a parser and a writer.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `content/*.md` | `boris-starlight-migration-lab` in provenance comment; `schemaVersion: 1` | `emitPage`, `emitSyntheticTrunk` | Lexicographic by entity ID | Not versioned per-file; no parser validation |
| `boundarymanifest.json` | Not versioned in file | `run()` JSON emission | N/A | Byte-identity tested across two runs |
| `relationcandidates.json` | Not versioned | `collectRelationCandidates` | Deterministic sort | Partial — sort order tested structurally |
| `assetsmanifest.json` | Not versioned | `enrichAssetsWithHashes` | Sorted by source path | Byte-identity tested (two-run) |
| `linkreview.json` | Not versioned | Link event emission | By source entity, line | Partial — test checks key strings present |
| All other JSON manifests | Not versioned | `run()` JSON emission | Varies | Uncertain |


***

## Determinism and reproducibility

The module is designed for byte-identical repeated runs on the same inputs. Two-run byte-identity is mechanically tested for `boundarymanifest.json`, `assetsmanifest.json`, and at least one converted page file (`content/features/alpha.md`) via the hostile and image-path fixture tests.[^1_2]

**Mechanisms:**

- Lexicographic path sorting for discovery and manifest ordering.
- Deterministic entity collision suffix assignment (`-2`, `-3`) based on path order.
- Deterministic relation candidate sort comparator (multi-field, fully specified).
- No timestamps in generated body content (`emitPage` does not include a timestamp field).
- No random identifiers in output.
- `schemaVersion` and `toolVersion` are compile-time constants, not runtime-computed.

**Oversized files:** No split-size or oversized-file behavior; the module converts individual pages, not a bundle partitioner. The `--max-pages` cap is the only size-limiting mechanism.


| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable discovery order | Lexicographic sort after walk | Directly demonstrated (hostile + image-path tests) | Filesystem walk order before sort is platform-dependent but overridden by sort |
| Stable manifest ordering | Explicit sort comparators | Structurally checked | Map iteration order in intermediate HashMaps not directly tested |
| No timestamps in output bodies | `emitPage` construction has no time calls | Structurally checked | `report.json` / `REPORT.md` not fully inspected for timestamp fields |
| Byte-identity of `boundarymanifest.json` | Two-run comparison in hostile test | Directly demonstrated | Cross-platform not tested |
| Byte-identity of `assetsmanifest.json` | Two-run comparison in image-path test | Directly demonstrated | Cross-platform not tested |
| Source immutability | Explicit before/after byte check in image-path test | Directly demonstrated | Only covers the image-path fixture specifically |
| No random identifiers | No `std.rand` usage in source excerpts | Structurally checked | Uncertain for fields not visible in excerpts |


***

## Filesystem and path safety

The module operates with the Zig `Io.Dir` abstraction. Source roots are opened as read-only directories. All write operations target the caller-supplied `--out` directory.[^1_2]

**Output-root containment:** `main.zig` enforces `--out != --root` before calling `starlight.run()`. Within `starlight.zig`, `outputPathFromEntity` constructs output paths as `content/<entity>.md` — relative strings without `..` components, derived from entity IDs that pass `isTargetLikeEntityId` validation (rejecting empty segments, `.`, `..`, and unsafe characters).[^1_2]

**`..` and path traversal in entity IDs:** `isTargetLikeEntityId` explicitly rejects strings containing `..` segments and empty path segments. `isBorisSafeWithinTree` (tested explicitly) rejects paths beginning with `..`. The `joinNormalized` function returns `null` for escape attempts; this is tested in `starlight joinNormalized resolves and rejects escape`.[^1_2]

**Asset path containment:** `joinNormalized` is used for within-tree asset path resolution. The test `starlight joinNormalized resolves and rejects escape` directly demonstrates that `joinNormalized("escape", "../../../../secret.png")` returns `null`.[^1_2]

**Symlinks:** Not explicitly handled. The source walk does not contain evidence of symlink rejection or following policy. This is a residual gap.

**Stale output cleanup:** Not evidenced. Previous output files in `--out` are not removed before a new run. This means a shrinking source set will leave orphaned files in `--out`. Not described as a defect—stale cleanup is simply not implemented.

**Replacement of previous output:** Output files are written (overwritten) directly. No atomic rename pattern is evidenced.

**Temporary files:** None evidenced. Output is written directly to the destination paths.


| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into source root | `--out != --root` checked in `main.zig` | Yes (pre-call check) | Indirectly (tests use separate dirs) | Caller could supply `--out` under `--root` as a subdirectory; not checked |
| Path traversal in entity ID → output path | `isTargetLikeEntityId` rejects `..`, `.`, empty segments | Yes | Partial (link resolution tested; output path construction indirectly) | Unicode normalization of entity paths not evidenced |
| Asset path escape | `joinNormalized` returns null for `..` escapes | Yes | Directly demonstrated | Symlinks in asset paths not handled |
| Stale output from prior run | None | No | No | Orphaned files persist across runs with changed source |
| Non-atomic output | Direct write without rename | No | No | Partial output if process is interrupted |
| Source file modification | No write calls to source dir | Structurally enforced | Directly demonstrated (byte-identity test) | Symlink from source into `--out` not tested |
| Recursive scan into `--out` | `isSkipDir` excludes `zig-out`, `dist`; `--out` not in skip list | Partial | No | If `--out` is named `content` and placed under `--root`, recursion is possible |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `formatId` | `pub const` string | Format identifier for provenance embedding | — | `"boris-starlight-migration-lab"` | Static |
| `schemaVersion` | `pub const u32` | Schema version constant | — | `1` | Static |
| `toolVersion` | `pub const` string | Tool version string | — | `"0.3.1"` | Static |
| `borisKeys` | `const` string array | Closed Boris frontmatter key allowlist | — | Used by `isBorisKey` | Static |
| `ContentShape` | `enum` | Content-root layout variant | — | `.localedir` or `.rootlocale` | — |
| `ContentRoot` | `struct` | Discovered content root descriptor | — | shape, relpath, routeprefix, locale | Allocated |
| `RunOptions` | `pub struct` | Caller-supplied run configuration | `sourcerootdir`, `outdir`, `locale`, `maxpages`, `quiet`, `borisbin` | Passed to `run()` | Borrowed from caller |
| `SourcePage` | `struct` | Per-page record after discovery and parse | All page fields | Used in conversion pipeline | Allocated per page |
| `StrippedBlock` | `struct` | Record of a stripped untrusted fence | `line`, `category` | In `boundarymanifest.json` | Allocated |
| `LinkEvent` | `struct` | Link or component mapping event | `kind`, `target`, `line`, `resolution`, `rewrittento`, `reviewreason`, `fragment` | In `linkreview.json` | Allocated |
| `AssetEntry` | `struct` | Asset inventory record | Source path, kind, exists, bytes, sha256hex, destpath | In `assetsmanifest.json` | Allocated |
| `MigratedAsset` | `struct` | Record of a proven migrated image | source/dest/within-tree paths, page entity, refs, bytes, sha256 | In `assetsmanifest.json` | Allocated |
| `NavDecision` | `struct` | Sidebar/nav evidence row | `kind`, `evidence`, `decision` | In `navflatten.json` | Allocated |
| `InventoryRow` | `struct` | File inventory row | `sourcepath`, `kind`, `bytes` | Intermediate | Allocated |
| `SelectionRow` | `struct` | Page selection decision row | `sourcepath`, `contentrel`, `selected`, `reason` | In `selectionmanifest.json` | Allocated |
| `BoundaryItem` | `struct` | Boundary classification row | `class`, `sourcepath`, `detail`, `line`, `category` | In `boundarymanifest.json` | Allocated |
| `CollisionRecord` | `struct` | Entity collision record | `entityid`, `sourcepaths`, `resolution` | In `unsupportedmanifest.json` | Allocated |
| `productRelationLimit` | `const usize` | Hard cap on proposed Boris relations per page | — | `16` | Static |
| `relationSourceFields` | `const` string array | Known Filed-shaped relation source fields | — | Used by `canonicalRelationSourceField` | Static |
| `RelationCandidate` | `struct` | Relation candidate row for sidecar | All resolution fields | In `relationcandidates.json` | Allocated |
| `RawRelationValue` | `struct` | Raw parsed relation value before resolution | source field, line, index, rawvalue, targetvalue, collection, reviewreason | Intermediate | Allocated |
| `FrontmatterLine` | `struct` | Parsed frontmatter line with position info | raw, text, start, end, indent, line | Intermediate | Allocated |
| `trims` | `fn` | Trim whitespace from string slice | slice | Trimmed slice | Borrowed |
| `isMarkdownName` | `fn` | Test if name ends in `.md` or `.mdx` | name | bool | — |
| `isBorisKey` | `fn` | Test if key is in closed Boris allowlist | key | bool | — |
| `isSkipDir` | `fn` | Test if directory name should be skipped | name | bool | — |
| `slugStem` | `fn` | Strip `.md`/`.mdx` extension | name | stem slice | Borrowed |
| `entityIdFromLocaleRel` | `fn` | Compute entity ID from locale-relative path | allocator, localerel | `![]u8` | Caller owns |
| `routeFromEntity` | `fn` | Compute route from entity ID and prefix | allocator, routeprefix, entityid | `![]u8` | Caller owns |
| `outputPathFromEntity` | `fn` | Compute output path from entity ID | allocator, entityid | `![]u8` (`content/<entity>.md`) | Caller owns |
| `looksLikeLocaleDirName` | `fn` | Test if dir name looks like a locale code | name | bool | — |
| `dirExists` | `fn` | Check if a directory exists under a root | io, root, rel | bool | — |
| `isCandidatePage` | `fn` | Exclude underscore partials | contentrel | bool | — |
| `discoverContentRoot` | `fn` | Locate content root for locale/root-locale | io, a, source, locale | `!ContentRoot` | Caller owns result |
| `titleFromStem` | `fn` | Generate title from entity ID stem | allocator, entityid | `![]u8` | Caller owns |
| `parseFrontmatterLite` | `fn` | Line-oriented frontmatter parser (no full YAML) | allocator, raw, fallbacktitle | `!struct{title, frontmatter, body, unmapped, allkeys}` | Caller owns |
| `stripUntrustedBlocks` | `fn` | Remove agent/directive/instruction/prompt fences | allocator, body | `!struct{body, blocks}` | Caller owns |
| `transformStarlightMdx` | `fn` | Convert Starlight MDX components to Boris equivalents | allocator, body | `!TransformedMdx` | Caller owns |
| `neutralizeDynamicAssetAttrs` | `fn` | Remove dynamic JSX asset attribute expressions | allocator, line, lineno, events, out | `!usize` (count removed) | Caller owns events |
| `sha256Hex` | `fn` | Compute lowercase hex SHA-256 of bytes | allocator, data | `![]u8` (64 chars) | Caller owns |
| `enrichAssetsWithHashes` | `fn` | Populate hash/size fields on asset entries | io, a, root, assets | `!void` | Mutates entries |
| `emitPage` | `fn` | Serialize a `SourcePage` to Boris candidate Markdown | allocator, page | `![]u8` | Caller owns |
| `emitSyntheticTrunk` | `fn` | Emit a synthetic trunk Markdown page | allocator, entityid, title | `![]u8` | Caller owns |
| `collectRelationCandidates` | `fn` | Extract and sort all relation candidates from pages | allocator, pages, routeprefix, entities | `![]RelationCandidate` | Caller owns |
| `run` | `pub fn` | Top-level entry point called by `main.zig` | io, allocator, `RunOptions` | `!void` (all outputs written to `--out`) | Process-scoped |
| Multiple `test` blocks | inline tests | Unit and integration tests for specific behaviors | Fixture directories, allocator | Pass/fail | Test lifetime |

**`run()` initialization sequence (inferred from source structure):**
The `run()` function accepts a GPA allocator and `RunOptions`. It opens the source root as a read-only `Io.Dir`, discovers the content root via `discoverContentRoot`, collects Markdown files, parses and selects candidate pages, processes each page (frontmatter parse, MDX transform, link rewrite, asset migration), builds all manifests, and writes all output files to the `--out` directory opened as a writeable `Io.Dir`. Cleanup order is not explicitly evidenced; `errdefer` usage on individual allocations is visible on the `TransformedMdx` fields but full cleanup-on-error coverage is uncertain.

***

## Ownership and lifetime model

**Process allocator:** `run()` receives a GPA (`gpa`) from `main`. The GPA is used for all allocations with cross-page lifetime. `main.zig` also provides an arena allocator for CLI argument parsing; this is separate from the GPA passed to `run()`.

**Page records:** Each `SourcePage` struct and its string fields (title, body, frontmatter, paths, events, stripped blocks) are allocated on the GPA. Ownership is retained by the `run()` function through the conversion pipeline.

**Transformation buffers:** `transformStarlightMdx`, `stripUntrustedBlocks`, and `neutralizeDynamicAssetAttrs` produce new `ArrayList(u8)` and `ArrayList(LinkEvent)` buffers with `errdefer buf.deinit(allocator)` / `errdefer events.deinit(allocator)` guarding partial allocations within those functions.[^1_2]

**Asset bytes:** Source asset bytes are read into allocator-owned slices in `enrichAssetsWithHashes`; the SHA-256 computation uses the bytes and the slice is freed. The hashes are stored as allocator-owned 64-byte hex strings in `AssetEntry`.

**Relation candidates:** `collectRelationCandidates` returns an allocator-owned slice. `seenproductrelations` (a `StringHashMapUnmanaged`) is allocated on the GPA within `collectRelationCandidatesForPage` and not explicitly freed in the visible excerpts — this is a residual lifetime uncertainty.

**Writer/file handle lifetime:** Output files are opened, written, and closed within the serialization pass of `run()`. No file handles are kept alive across multiple serialization steps.

**Cleanup on error:** `errdefer` is used on intermediate buffers within transformation functions. Full GPA cleanup on error propagation from `run()` is not explicitly evidenced in available excerpts; the GPA is owned by `main` which exits immediately after `run()` returns, so OS-level reclaim applies regardless.

**Leak freedom:** Not claimed. No allocator check wrapper (e.g., `std.testing.allocator` leak detection) is used in integration tests that exercise `run()` directly; `std.testing.allocator` is used in unit tests, providing leak detection for those paths.[^1_2]

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Unknown CLI flag | `parseOptions()` in `main.zig` | `std.log.err("unknown argument, try --help")` | Exit 2 | No output written |
| Missing flag value | `parseOptions()` | `std.log.err("missing value for flag")` | Exit 2 | No output written |
| Invalid flag value (bad int for `--max-pages`) | `parseOptions()` | `std.log.err("invalid flag value")` | Exit 2 | No output written |
| `--out` same as `--root` | `main()` before `run()` | `std.log.err(...)` | Exit 2 | No output written |
| `error.ContentRootNotFound` | `discoverContentRoot()` | Propagated as Zig error → `std.log.err("migration-lab starlight failed: <error>")` | Exit 3 | No output written |
| Unreadable source file | File open/read within `collectMarkdownFiles` or page parsing | Error propagated or asset marked `exists: false` | Exit 3 or review event | Partial: manifests may be written, then fail |
| Output directory creation failure | `run()` output dir open/create | Error propagated | Exit 3 | Partial output possible |
| Serialization/write failure | JSON/Markdown write calls | Error propagated | Exit 3 | Partial output possible |
| Asset copy failure | `enrichAssetsWithHashes` / asset migration | Asset marked `exists: false`; review event | No abort; run continues | Asset missing from output |
| Optional Boris compile failure | Subprocess invocation | Recorded in `compilereport.json` | No abort | `compilereport.json` reflects failure |
| Allocation failure | Any GPA allocation | `error.OutOfMemory` propagated | Exit 3 | Partial output possible |

Diagnostics are produced via `std.log.err` (plain stderr). No structured diagnostic format is used at the top-level error reporting layer. Within manifests, errors are represented as structured review events with `reviewreason` strings.[^1_3]

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Dispatcher; calls `starlight.run()` and passes `RunOptions` | `main.zig` → `starlight.zig` | `main.zig` owns CLI surface |
| `tools/migration-lab/build.zig` | Build integration; compiles both into `boris-migration-lab` | Build declaration | `build.zig` |
| `tools/migration-lab/README.md` | Documentation; describes Starlight mode, CLI, fixtures, safety rules | Documentation | `README.md` (verify against source) |
| `tools/migration-lab/fixtures/image-path-starlight/` | Test fixture; F-L1 image resolution matrix | Test fixture | Source behavior |
| `tools/migration-lab/fixtures/hostile-starlight/` | Test fixture; adversarial inputs | Test fixture | Source behavior |
| `tools/migration-lab/fixtures/dogfood-starlight/` | Test fixture; 67-page realistic dogfood | Test fixture | Source behavior |
| `tools/migration-lab/fixtures/mini-starlight/` | Test fixture; compact locale-dir | Test fixture | Source behavior |
| `tools/migration-lab/fixtures/mini-starlight-root/` | Test fixture; compact root-locale | Test fixture | Source behavior |
| `tools/migration-lab/fixtures/dynamic-asset-starlight/` | Test fixture; dynamic JSX asset | Test fixture | Source behavior |
| `tools/migration-lab/themearchaeology.zig` | Sibling module in same package; shares no imports with starlight.zig | Sibling module | Independent |
| `--out/content/*.md` | Generated output; Boris candidate Markdown | Output | Not authoritative |
| `--out/boundarymanifest.json` | Generated output; boundary evidence | Output | Not authoritative |
| `--out/relationcandidates.json` | Generated output; relation candidate sidecar | Output | Not authoritative |
| Boris product `src/` | Not imported; not a dependency | None | Fully separate |
| Root `build.zig` | Not referenced | None | Fully separate |


***

## Security and trust boundaries

`tools/migration-lab/starlight.zig` processes untrusted third-party Markdown and MDX content. The following boundaries apply:

**Untrusted source bytes:** All `.md` and `.mdx` file content is treated as untrusted. Frontmatter is parsed with a line-oriented, no-full-YAML parser (`parseFrontmatterLite`) that reads only closed Boris keys; all other keys are inventoried as unmapped. No YAML evaluation, no arbitrary value interpretation.

**Embedded directives/prompts:** `stripUntrustedBlocks` explicitly removes fences matching `agent`, `directive`, `instruction`, `prompt` categories (both regular and code-fence variants, and HTML tag variants). Stripped payloads are never replayed; only the category and line number are recorded. This is structurally enforced, not caller-discipline.[^1_2]

**Dynamic JSX expressions:** `neutralizeDynamicAssetAttrs` removes dynamic asset attribute values from JSX/HTML tags. The removed expression is recorded as a review event; it is never evaluated or executed. Static attributes (string values) are preserved byte-for-byte.[^1_2]

**MDX import/component execution:** Not performed. Import paths are extracted and inventoried; component tags are mapped or recorded as review items. No MDX runtime, no Node.js, no JavaScript evaluation.

**Markdown fence safety:** Standard Markdown fences in body content are preserved. The tool does not re-render Markdown, so fence injection into the output is possible if source content contains carefully crafted fences that interact with Boris's rendering pipeline. This is a residual gap not addressed by the tool.

**Embedded frontmatter in packed documents:** The migration provenance comment (`<!-- boris-migration-provenance ... -->`) is appended to generated Markdown. If a source page's body contains a closing `-->` sequence it could interfere with this comment structure. Not evidenced as mitigated.

**Path traversal:** `isTargetLikeEntityId` and `isBorisSafeWithinTree` reject `..` components and unsafe characters in entity IDs and within-tree asset paths. `joinNormalized` returns `null` for escape attempts. Tested directly. Symlinks in the source tree are not explicitly handled.

**Output overwrite:** Previous `--out` contents are overwritten. No checksum guard or version tag prevents overwriting a previous valid output with a corrupted one if the source is modified adversarially.

**Resource exhaustion:** No per-file size limit is imposed before reading file bytes into memory. A very large source file will be read entirely into the GPA. `--max-pages` limits page count but not individual file size or total asset bytes.

**Maliciously chosen filenames:** Filenames are used to derive entity IDs via `entityIdFromLocaleRel`. The `isTargetLikeEntityId` validator rejects many unsafe characters, but Unicode normalization attacks (e.g., visually identical entity IDs from different Unicode code points) are not explicitly addressed.

**Terminal output:** Progress lines and error messages are written via `std.log.err` and `std.debug.print`. No ANSI escape sanitization is applied to filenames that may appear in error messages, creating a potential terminal injection surface for adversarially named files.

**Network exfiltration:** Absent. No network API is called. Structurally enforced by Zig stdlib-only dependency.

**Validation vs. copying:** Source asset bytes are copied opaque (byte-for-byte) into `--out`. The tool does not validate asset content (e.g., does not reject SVG with embedded scripts). The output asset bytes are identical to source bytes.

***

## Evidence limitations

- **`run()` full source not available:** The complete body of the `run()` function was not available in the excerpted source; its full manifest serialization sequence, error handling, and cleanup order are inferred from struct definitions, helper functions, README descriptions, and test behavior.
- **`stale output cleanup`:** No evidence of stale file deletion; this behavior is uncertain/absent.
- **`report.json` / `REPORT.md` serialization:** Exact field set and format for these files was not directly evidenced from available source excerpts.
- **`compilereport.json` behavior:** The Boris subprocess invocation mechanism is described in README and CLI but the subprocess-handling code was not in available excerpts; behavior when the binary is missing is inferred.
- **Symlink handling:** No evidence in available source of explicit symlink policy in the directory walk or asset copy path. Gap is unresolved.
- **Cross-platform byte-identity:** Tests run on a single CI host. Platform-separator behavior in path strings and `\r\n` vs `\n` are not tested across platforms.
- **`headingfragments.json` format:** Structure not directly evidenced from available source.
- **`navflatten.json` format:** Structure described in README but not directly evidenced from serialization code.
- **`relationcandidates.json` golden test:** No golden-output comparison test was evidenced for this manifest; only structural sort guarantees.
- **`seenproductrelations` cleanup:** The `StringHashMapUnmanaged` inside `collectRelationCandidatesForPage` is not visibly freed in the available excerpt; potential GPA leak.
- **`--boris` subprocess implementation:** The compile verification subprocess call was not in available source excerpts; behavior is inferred from README and `compilereport.json` output description.
- **Frontmatter with non-ASCII keys:** Not directly evidenced as handled or rejected.

***
