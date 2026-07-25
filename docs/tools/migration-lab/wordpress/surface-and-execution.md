---
title: "`tools/migration-lab/wordpress.zig` surface and execution"
id: docs/tools/migration-lab/wordpress/surface-and-execution
parent: docs/tools/migration-lab/wordpress
status: draft
tags: [boris, zig, tools, surface, migration-lab, wordpress]
---

# `tools/migration-lab/wordpress.zig` surface and execution

## CLI surface

The CLI is parsed entirely by `main.zig`; `wordpress.zig` receives only the resolved `RunOptions` struct. The flags relevant to WordPress mode are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--wxr &lt;FILE>` or `--wxr=&lt;FILE>` | Yes (for WordPress mode) | none | Any non-empty path | Path to WXR XML export; also implies `--mode wordpress` when mode is still default | Missing value → exit 2 + usage; absent in wordpress mode → exit 2 + usage |
| `--media &lt;DIR>` or `--media=&lt;DIR>` | No | none (null) | Any non-empty path | Optional local media/uploads mirror; never modified | Missing value → exit 2 |
| `--out &lt;DIR>` or `--out=&lt;DIR>` | No | `migration-report` | Any non-empty path | Output directory; created if missing | Must differ from `--wxr` and `--media`; violation → exit 2 |
| `--mode wordpress` (or `wp`, `wxr`) | No | auto-inferred from `--wxr` | `wordpress`, `wp`, `wxr` | Selects WordPress mode | Invalid value → exit 2 |
| `-q`, `--quiet` | No | false | flag | Suppresses progress output to stderr | — |
| `-h`, `--help` | No | false | flag | Prints full usage text and exits 0 | — |

**Exit codes:**

- `0` — success
- `2` — usage error (unknown flag, missing value, invalid value, missing required input, path collision)
- `3` — I/O error (WXR read failure, output write failure, XML parse error mapped to error name)

Unknown flags produce exit 2. Invalid mode values produce exit 2. Missing `--wxr` in wordpress mode produces exit 2 with usage text.

Exact numeric exit codes are confirmed by `ExitCode` enum in `main.zig` (`success = 0`, `usage = 2`, `ioerror = 3`).

***

## Inputs and discovery model

| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| WXR XML export (`--wxr`) | Single explicit file path, opened directly | All `<item>` elements; `<wp:author>`, `<wp:term>` elements | None filtered at read level | Implementation: `parseWxr` / pull-parser walk |
| Local media directory (`--media`) | Optional explicit directory; walked recursively via `collectMediaFiles` | All regular files | Directories named `.git`, `node_modules`, `dist`, `zig-out`, `.zig-cache`, `migration-report` | `isSkippedDir` check in walk; structurally enforced |
| Media filename matching | `matchMediaReference`: strips query strings and fragments; tries upload-key lookup; falls back to basename match | Files whose path suffix or basename matches a harvested URL | Symlinks (rejected), duplicate basenames (flagged ambiguous) | Implemented in `matchMediaReference`, `isSymlink`, duplicate-basename detection loop |

**WXR item selection:** Only `posttype = "post"` and `posttype = "page"` items are converted to content pages. All other post types (attachment, nav_menu_item, wp:block, wp:template, wp:navigation, and custom types) are preserved verbatim under `content/preserved<type>-<postid>.md` and recorded in the unsupported list.

**Symlink policy:** Symlinks in the media tree are detected and rejected; the corresponding manifest entry is marked `symlinkescape`. This is structurally enforced.

**Path normalization:** Media references (URLs) have query strings and fragments stripped before matching. Percent-decoding is applied to media URLs during lookup (`toolversion 0.4.1` note: "percent-decoded lookup"). `srcset` and `data-src` attributes are harvested in addition to `src=`.

***

## Output artifact model

All outputs are written under `<outdir>/`. On re-run, `content/` is deleted and recreated via `deleteTree`, and individual report sidecars (`report.json`, `REPORT.md`, `mediamanifest.json`) are deleted individually before regeneration. This is a deterministic wipe of lab-owned outputs, not a generic clear of all files under `--out`.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/<type>/<slug>.md` | Markdown with Boris frontmatter | Lab-generated; disposable | Sorted by entity-ID (lexicographic) | Human author; Boris compiler after review | Not versioned; structure follows `schemaversion 3` |
| `content/posts.md` (trunk stub) | Boris Markdown | Lab-generated; disposable | — | Human author; Boris compiler | Same |
| `content/pages.md` (trunk stub) | Boris Markdown | Lab-generated; disposable | — | Human author; Boris compiler | Same |
| `content/preserved<type>-<id>.md` | Boris draft Markdown (unsupported items) | Lab-generated; disposable | By post type + post ID | Human review | Same |
| `content/preservedcomments-<postid>.md` | Boris draft Markdown | Lab-generated; disposable | By post ID | Human review | Same |
| `content/<slug>.assets/<filename>` | Binary copy of source media file | Lab-generated; disposable | — | Boris compiler; browser | Byte-for-byte copy, SHA-256 verified against media tree |
| `report.json` | JSON, format `boris-wordpress-migration-lab`, schema version 3 | Lab-generated; disposable | Pages sorted by `outputpath`; links by `sourceoutput`+`target`; media by `sourceoutput`+`referenced`; features by `sourcepostid`+`code` | Human author; tooling | Not externally versioned beyond `schemaversion` field |
| `REPORT.md` | Human-readable Markdown summary | Lab-generated; disposable | Derived from sorted report arrays | Human author | Unstable across versions |
| `mediamanifest.json` | JSON, format `boris-wordpress-migration-lab`, schema version 3 | Lab-generated; disposable | Sorted by `sourceoutput`+`originalreference`+`status` | Human author; tooling | Same |

**Required for a minimally useful migration:** `content/` tree + `report.json` + `mediamanifest.json`.

**Optional / convenience:** `REPORT.md`.

**Not produced by this module:** catalog metadata, part manifests, upload manifests, combined bundles—those are source-RAG concerns.

***

## Serialization and schema behavior

The module emits JSON using hand-written `appendJson` helpers, not `std.json.stringify`. JSON strings are escaped by iterating bytes: `"`, `\`, `/`, newlines (`\n`, `\r`), tabs (`\t`), and control characters below 0x20 are escaped. Field ordering within objects is fixed by emission order in code. Array ordering is determined by explicit sort before emission.

Boris frontmatter (YAML-like) in Markdown files is emitted via `buildFrontmatter`, using explicit field ordering: `id`, `title`, `parent` (if present), `status`, `tags` (if present).

Provenance comments are emitted as HTML comments (`<!-- boris-migration-provenance ... -->`) embedded in each generated Markdown page, recording `format`, `sourcepath`/export path, `postid`, `posttype`, `guid`, `postname`, `author`, `postdate`, `link`, and `conversion`.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` | `boris-wordpress-migration-lab`, schema version 3 | `emitReport` (inlined in `run`) | Pages by outputpath; links by sourceoutput+target; media by sourceoutput+referenced+status; features by sourcepostid+code | Tested via fixture comparison (content presence); no schema validator in evidence |
| `mediamanifest.json` | `boris-wordpress-migration-lab`, schema version 3 | `emitMediaManifest` (inlined in `run`) | By sourceoutput+originalreference+status | Fixture tests; no schema validator |
| Generated Markdown frontmatter | Follows Boris closed grammar (id, title, parent, status, tags) | `buildFrontmatter` | Fixed field order | Indirectly by boris compile-check in Starlight mode; not directly for WP mode |
| Provenance HTML comment | Embedded convention; no external schema | `buildProvenanceComment` | Fixed | Not validated |

Schema version 3 is declared in the `schemaversion` constant. No backward compatibility handling for earlier schema versions is present in the module—this tool does not read its own output.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Output page ordering | Explicit `std.mem.sort` on `metas` by `entityid` before emission | Structurally checked | Map iteration (slug-to-IDs hash map) is not sorted before use in conflict detection, but final sort of `pages` by `outputpath` covers emission order |
| Entity-ID and output-path construction | Deterministic slug synthesis from `postname` or title, type-prefixed path, collision suffix from `postid` | Structurally checked | Title-based slug synthesis may produce different results if title contains characters outside `[a-z0-9]` in ways not covered by tests |
| Report array ordering | Explicit sort of `pages`, `parents`, `alllinks`, `allmedia`, `missing`, `mediamanifest`, `allfeatures`, `slugconflicts`, `allcomments` before emission | Structurally checked | Sort comparators use lexicographic order on `outputpath` / `sourceoutput` / `target`; no test explicitly compares two independent runs for byte identity |
| Media file ordering for duplicate-basename detection | `std.mem.sort` on media file list by path | Structurally checked | Filesystem enumeration order prior to sort is not guaranteed across platforms |
| No timestamps in frontmatter | `buildFrontmatter` does not include a timestamp field | Structurally checked | `postdate` is preserved in `report.json` as metadata but not in page frontmatter |
| No absolute paths in output | Output paths are constructed relative to `outdir` and `content/` prefixes | Structurally checked | Not directly tested for adversarial inputs |
| Media SHA-256 verification | Recorded ledger SHA-256 compared against actual bytes before copy | Structurally checked | Only applies when archaeology ledger provides a hash; WP media copies use live hash of source |
| Cross-platform byte identity | Not demonstrated | Uncertain | Platform path separator, filesystem enumeration order, and potential endianness in any binary handling are not CI-tested across platforms |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output inside WXR input | `main.zig` guards `--out != --wxr` before dispatch | Yes (in main.zig, before run) | Not a dedicated unit test; enforced structurally | Bypassed if `RunOptions` constructed directly |
| Output inside media input | `main.zig` guards `--out != --media` before dispatch | Yes (in main.zig) | Same | Same |
| Symlink traversal in media tree | `isSymlink` check; rejected with `symlinkescape` reason | Yes | Fixture: `fixtures/hostile-asset-filenames` includes symlink case; coverage in `wordpress.zig` tests uncertain | Symlinks in WXR XML path itself not checked |
| Path traversal in media filenames | `withinTreeForMedia` + `isSafeRelativePath`-style validation on materialized asset destinations | Partial | `hostile-asset-filenames` fixture exercises asset sanitization; dedicated WXR-media traversal tests not confirmed | Full coverage uncertain |
| Stale content from prior run | `deleteTree(contentpath)` + explicit sidecar `deleteFile` calls | Yes (scoped delete) | Not a standalone test; observed in code | If delete fails, error is silently caught (`catch {}`) — stale files may persist without diagnostic |
| Partial media copy on failure | None (no staging/rename strategy) | No | Not tested | Interrupted copy leaves partial file at destination |
| Accidental recursion into own output | `--out` must differ from input; re-run wipe deletes `content/` first | Partial | Structurally enforced for same-directory case; not tested for subdirectory cases | If `--out` is a subdirectory of the media tree, not caught by current guard |
| Duplicate destination paths for media | `usedWithin` hash map tracks used destinations; duplicates get disambiguated suffix | Yes | Indirectly via duplicate-basename test cases | Race condition not relevant (single-threaded) |
| Very large WXR files | No streaming parser; full XML read into memory | No | Not tested | May exhaust process memory on large exports |

The stale-output `deleteTree` catch is silent: `Io.Dir.cwd.deleteTree(io, contentpath) catch {}`. If a prior run's `content/` cannot be deleted (e.g., permission error), execution continues and may mix old and new content without warning.

***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const []const u8` | Format identifier for machine files | — | `"boris-wordpress-migration-lab"` | Static |
| `schema_version` | `pub const u32 = 3` | Schema version embedded in JSON output | — | `3` | Static |
| `tool_version` | `pub const []const u8 = "0.4.1"` | Tool version embedded in reports | — | `"0.4.1"` | Static |
| `high_cardinality_taxonomy_threshold` | `pub const usize = 50` | Site-level taxonomy count above which high-cardinality flag is emitted | — | `50` | Static |
| `high_cardinality_terms_threshold` | `pub const usize = 15` | Per-page category+tag count threshold | — | `15` | Static |
| `long_title_threshold` | `pub const usize = 80` | Title byte length above which `longtitle` feature code is emitted | — | `80` | Static |
| `RunOptions` | `pub const struct` | Configuration passed from `main.zig` dispatcher | — | Holds `wxrpath`, `mediadir`, `outdir`, `quiet` | Borrowed from caller; all fields are `[]const u8` slices |
| `ConversionClass` | `pub const enum` | Per-item conversion quality classification | — | `.exact`, `.transformed`, `.unsupported`, `.humanreview` | — |
| `WxrItem` | `pub const struct` | Parsed representation of a WXR `<item>` | — | Holds all relevant WXR fields as `[]const u8` slices | Arena-owned |
| `WxrDocument` | `pub const struct` | Root parsed WXR document | — | Holds `authors`, `taxonomies`, `items` | Arena-owned |
| `PageRecord` | `pub const struct` | Per-page migration result record | — | Feeds into `report.json` and `REPORT.md` | Arena-owned |
| `run` | `pub fn (Io, gpa, RunOptions) !void` | Primary entry point; full migration pipeline | WXR file, optional media dir | Writes `content/`, `report.json`, `REPORT.md`, `mediamanifest.json` | Owns arena; cleans up on defer |

**`run` initialization sequence:**

1. Arena allocator initialized over GPA; deferred `deinit`.
2. Output directory created (`createDirPath`); opened.
3. WXR file read into arena memory; parsed.
4. Media file list collected from optional media dir; sorted.
5. Items indexed by post-ID and slug.
6. `ItemMeta` list built; duplicate output paths detected and disambiguated.
7. Metas sorted by entity-ID.
8. Stale `content/` wiped; report sidecars deleted.
9. Per-item conversion loop: body conversion, media harvest, media matching, link resolution, parent mapping, status mapping, feature-code accumulation, file emission.
10. Unsupported post types preserved.
11. Trunk stubs emitted.
12. Slug-conflict list built and sorted.
13. All report arrays explicitly sorted.
14. `report.json`, `REPORT.md`, `mediamanifest.json` emitted.
15. Optional progress message to stderr.

Error propagation: all `try` expressions propagate Zig errors. The caller (`main.zig`) maps any error to `ExitCode.ioerror` (exit 3) with `@errorName(err)` on stderr.

***

## Ownership and lifetime model

The `run` function uses a two-allocator strategy:

- **`gpa`** (passed in): used for collections that outlive individual item processing and are needed for the final sort-and-emit phase (`ArrayList(PageRecord)`, `ArrayList(MediaRef)`, etc.) and for certain short-lived allocations that require freeing (media file list, stale-path strings).
- **`retain`** (arena over GPA, initialized in `run`): used for all string content—entity IDs, output paths, frontmatter text, body text, feature-code strings, provenance strings. Deferred `arena.deinit()` frees all retained strings on function exit.

Most string fields in `PageRecord`, `LinkFinding`, `MediaRef`, `FeatureFinding`, `Provenance`, etc. are owned by the arena and become invalid after `run` returns. The function completes all emission before returning, so this is safe.

ArrayList collections allocated via `gpa` have explicit `defer deinit` calls. Media file list has `defer gpa.free(mediafiles)`.

**Lifetime assumptions enforced only by convention:**

- The `RunOptions` struct fields (`wxrpath`, `mediadir`, `outdir`) are borrowed from the caller (process arguments arena in `main.zig`); the module never frees them. If `run` is called from a context where argument memory is released before `run` completes, these would be dangling. In the actual call path, process argument lifetime exceeds `run` lifetime.
- Whether GPA-based collections are fully freed on all error paths is not confirmed by allocator-checking tests in available evidence.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Missing `--wxr` in wordpress mode | `main.zig` before dispatch | `std.log.err` + usage text | Exit 2 | None |
| `--out` equals `--wxr` or `--media` | `main.zig` before dispatch | `std.log.err` message | Exit 2 | None |
| WXR file unreadable | `run`: file open | Error propagated; `main.zig` prints `errorName` | Exit 3 | Output dir may have been created |
| XML parse error | `parseWxr` | Error propagated | Exit 3 | Partial output possible if run partially |
| Output directory creation failure | `createDirPath` | Error propagated | Exit 3 | None |
| Stale `content/` delete failure | `deleteTree` | **Silent** (error caught with `catch {}`) | Continues | Stale content may persist |
| Individual file write failure | `writeBytes` via `try` | Error propagated | Exit 3 | Partial output (files written before failure remain) |
| Individual media file unreadable | `readFile` for media copy | Entry marked `rejected`; reason in manifest | Continues (non-fatal) | Affected page body not rewritten |
| Symlink in media tree | `isSymlink` check | Entry marked `symlinkescape`; reason in manifest | Continues | None |
| Duplicate media basename | Loop detection | Entry marked `ambiguous`; feature code emitted | Continues | None |
| Unknown flag / missing value / invalid value | `parseOptions` in `main.zig` | `std.log.err` + usage text | Exit 2 | None |
| Out of memory | Allocator returns error | Error propagated; `main.zig` prints `errorName` | Exit 3 | Partial output possible |

Diagnostics are a mix of `std.log.err` (structured, goes to stderr with log prefix) for CLI errors, and `@errorName(err)` formatting in `main.zig`'s catch for runtime errors. There is no structured diagnostic format for runtime errors beyond the Zig error name.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Importer and dispatcher; calls `wordpress.run` | `main.zig` → `wordpress.zig` | `main.zig` owns CLI parsing and exit behavior |
| `tools/migration-lab/build.zig` | Build integration; compiles both into `boris-migration-lab` | `build.zig` → module graph | Authoritative for build |
| `fixtures/mini-wxr/export.xml`, `fixtures/mini-wxr/media/` | Test fixture | Consumed by inline tests | Primary integration evidence |
| `fixtures/unit-wxr/export.xml`, `fixtures/unit-wxr/media/` | Test fixture (full coverage matrix) | Consumed by inline tests | Primary behavioral evidence |
| `fixtures/media-wxr/` | Test fixture (media reference matrix) | Consumed (extent uncertain) | Supporting evidence |
| `fixtures/wptt-derived/` | Documentation of hostile cases | Documentation only (external file required) | Documented contract |
| `fixtures/mini-wordpress-kubrick/` | Fixture for `wordpresstheme.zig` mode | Not consumed by `wordpress.zig` | Unrelated |
| `tools/migration-lab/wordpresstheme.zig` | Sibling module for WP PHP theme archaeology mode | Independent; no shared code | Sibling tool |
| `tools/source-rag/` | Sibling tool tree | No relationship | Unrelated |
| Boris product compiler (`src/`) | No import, no coupling | None | Fully separate |
| `docs/MIGRATION.md` | Companion author guide | Documentation | Supplementary |
| `tools/migration-lab/README.md` | Tool-level documentation | Documentation | Secondary evidence |


***

## Security and trust boundaries

**Untrusted XML input:** The WXR file is parsed by a custom pull-parser. The parser does not execute external entities, does not resolve DTDs, and does not fetch remote resources. All extracted values are `[]const u8` slices into the read buffer. No entity expansion is performed (XML entity references in WXR content fields such as `&amp;`, `&lt;` are passed through opaque to the Markdown output—they are not decoded and re-encoded; this may affect downstream rendering).

**Arbitrary source-file bytes in body:** `contentencoded` (HTML body) is carried as opaque bytes into the Markdown output. No HTML sanitization is performed. If the source WXR contains script tags, they are preserved in the output Markdown. The generated Markdown is not safe for arbitrary execution downstream without author review.

**Markdown fence safety:** The module wraps preserved HTML content in fenced code blocks (````html`) for unsupported item types and attachment/comment bodies. Whether fence injection (a body containing ````` at the start of a line) can escape the fence and be interpreted as executable content by downstream processors is not addressed by the implementation or tests.

**Embedded provenance comments:** Provenance HTML comments (`<!-- boris-migration-provenance ... -->`) are embedded in output Markdown. Field values within comments are taken directly from WXR metadata (title, postname, author, etc.) without escaping for HTML comment context. A `-->` sequence in a field value could prematurely terminate the comment.

**Path traversal in media destinations:** Asset destination paths are constructed as `<slug>.assets/<withinPath>`. `withinTreeForMedia` and `disambiguateWithin` shape the within-path; `isSafeRelativePath` validation is used in the materialize mode but its application specifically to every WP media destination is not fully confirmed by isolated tests.

**Output overwrite:** Existing files at destination paths are overwritten without prompting. The stale-`content/` wipe happens silently if `deleteTree` fails.

**Resource exhaustion:** The full WXR file is read into memory before parsing. Very large exports (multi-MB) may cause arena exhaustion. No size limit is enforced.

**Maliciously chosen filenames:** WXR `postname` values and media filenames are inputs to entity-ID construction and asset path construction. Sanitization via `sanitizeEntitySegment` and `slugify` reduces but may not eliminate all hazards from adversarially crafted values; dedicated hostile-WXR tests are not confirmed in available evidence.

**Terminal output:** Progress messages printed via `std.debug.print` include the `--out` path value and item counts. If `--out` is a path containing terminal escape sequences, they would be echoed to stderr.

**Network:** No network access. Confirmed structurally and by README documentation.

**Trust model summary:**


| Input | Treatment |
| :-- | :-- |
| WXR file path | Trusted (caller-supplied; no traversal check at this level) |
| WXR XML content | Opaque bytes; XML pull-parsed; no entity execution |
| WXR body/title/metadata fields | Copied opaque into output; not escaped for Markdown or HTML comment context |
| Media filenames | Partially sanitized via slug/segment normalization; adversarial coverage uncertain |
| Media file bytes | Copied byte-for-byte after SHA-256 verification |
| `--out` directory | Guarded against equaling inputs; not checked for being a sub-path of input media |


***

## Evidence limitations

- `fixtures/wptt-derived/` references an external file (WordPress Theme Unit Test WXR) that is not committed. Claims about hostile/high-cardinality behavior from that fixture are documented contracts, not directly executable tests in this pack.
- The exact content of all inline Zig tests was not fully reproduced in available source evidence; test bodies are partially visible via source-RAG fragments. Some claimed coverage matrix rows may correspond to fixture data rather than inline assertions.
- Whether the test runner uses a leak-detecting allocator (e.g., `std.testing.allocator`) for all allocations in `wordpress.zig` inline tests is uncertain; some sub-allocations use `gpa = std.testing.allocator` but the full arena interaction is not confirmed.
- Cross-platform (Windows) behavior is undocumented and untested in available evidence. Platform path separator handling and filesystem enumeration determinism on Windows are uncertain.
- The behavior of the HTML pull-parser on malformed or truncated XML is not covered by dedicated error-path tests in available evidence.
- Whether `isSafeRelativePath` is applied to every media asset destination path constructed during WP mode (not just materialize mode) is inferred from control flow but not confirmed by an isolated test.
- Schema version 3 is declared; no evidence of version migration logic for consumers reading older-format output.
- The `REPORT.md` format is not versioned or schema-defined; its structure may change without a version increment.
- `fixtures/media-wxr/README.md` documents a media-reference coverage matrix whose association with committed inline tests versus documentation-only claims is uncertain from available source bundles.

***

## Final source assessment

`tools/migration-lab/wordpress.zig` is the complete, self-contained core of the WordPress WXR migration mode. It performs XML parsing, content conversion, media materialization, parent-hierarchy mapping, feature-code accumulation, and deterministic report emission. It is fully isolated from the Boris product compiler with no shared module dependencies.

**Strongest supported guarantees:** Read-only on inputs (structurally enforced); no network access (structurally enforced); symlink rejection in media tree (structurally enforced); explicit sort-based determinism for all output arrays and file ordering; stale-output scoped wipe on re-run; schema version 3 embedded in all machine output.

**Weakest or least-tested boundaries:** Silent failure on stale-output delete; no byte-identity repeated-run test; no adversarial XML or malformed-input tests; provenance comment field injection; symlink rejection not confirmed in WP-specific inline tests; cross-platform behavior entirely unverified.

**Separation from Boris product runtime:** Complete. The module is not imported by, does not import from, and is not compiled into the `boris` product binary. It is accessible only via the standalone `tools/migration-lab/build.zig` build.

**Quality of available evidence:** Good for integration behavior (fixture-driven inline tests cover most WXR behavioral cases); weak for adversarial inputs, error paths, cross-platform behavior, and byte-level determinism.

**Most important unresolved question:** Whether the deterministic sort ordering produces byte-identical output across independent runs on the same input, particularly given hash-map iteration in intermediate phases—this has not been verified by any repeated-run comparison test.
