---
title: "`tools/migration-lab/instagram.zig` surface and execution"
id: docs/tools/migration-lab/instagram/surface-and-execution
parent: docs/tools/migration-lab/instagram
status: draft
tags: [boris, zig, tools, surface, migration-lab, instagram]
---

# `tools/migration-lab/instagram.zig` surface and execution

## CLI surface

Instagram mode arguments are parsed entirely in `main.zig`; `instagram.zig` receives only the resolved `RunOptions` struct. The following CLI flags are relevant to this mode:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode instagram` / `--mode ig` / `--mode takeout` | No (implied by `--dump`) | `astro` | String aliases listed | Selects Instagram mode explicitly | `error.InvalidValue` → exit code 2 |
| `--dump &lt;DIR>` | Yes (for instagram mode) | None | Any non-empty path | Sets dump root; implies `--mode instagram` | Missing value → `error.MissingValue` → exit 2; absent in instagram mode → usage error, exit 2 |
| `--out &lt;DIR>` | No | `migration-report` | Any non-empty path | Sets output root; must differ from `--dump` | If equal to `--dump` → stderr error, exit 2 |
| `--quiet` / `-q` | No | off | Flag presence | Suppresses progress lines to stderr | N/A |
| `--help` / `-h` | No | off | Flag presence | Prints usage and exits 0 | N/A |

Exit codes: `0` success, `2` usage/CLI error, `3` I/O or runtime error. Exact codes are declared in `main.zig` as `pub const ExitCode enum(u8) { success = 0, usage = 2, ioerror = 3 }` and confirmed by direct test.

Unknown flags → `error.UnknownFlag` → exit 2. Invalid `--mode` value → `error.InvalidValue` → exit 2. These are directly demonstrated by `main.zig` tests (`test "parseOptions unknown flag"`, `test "parseOptions invalid mode"`).

***

## Inputs and discovery model

`instagram.zig` reads from the `--dump` directory, which is expected to be an unpacked Meta "Download your information" export. No ZIP extraction is performed; the archive must be unpacked before invocation.

The expected content layout is:

- `your_instagram_activity/content/posts.json` or `posts.html` (and optionally `posts_2.json`, etc., for multi-part exports)
- `your_instagram_activity/content/reels.json`
- `your_instagram_activity/content/stories.json`
- `your_instagram_activity/content/` (other-content JSON files)
- Local media tree referenced by URIs in the JSON export (paths relative to the dump root)

| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| JSON post records | `your_instagram_activity/content/posts*.json` | Yes | None stated beyond directory skip list | Source: `RunOptions.dumpdir` walk |
| HTML post records | `posts*.html` fallback when JSON absent or supplemented | Yes | None stated | `parseHtmlPostsFile` declared in source |
| Reels JSON | `your_instagram_activity/content/reels.json` | Yes | None | Source |
| Stories JSON | `your_instagram_activity/content/stories.json` | Yes | None | Source |
| Other-content JSON | `your_instagram_activity/content/othercontent.json` et al. | Yes | None | Fixture: `othercontent.json` |
| Media files | URI paths from JSON/HTML records, resolved relative to dump root | Conditional | Paths failing `isSafeMediaUri` rejected entirely | `isSafeMediaUri` implementation |
| Skipped directories | `.git`, `.DS_Store`, `zig-cache`, `.zig-cache` | Skipped | — | `isSkippedDirName` implementation |

Media URIs that fail the safety check are not read. The record is classified `humanreview` and appears in the report as `unsafe media uri rejected`.

***

## Output artifact model

All outputs are written under the `--out` directory. The tool does not write staging paths or temporary files visible outside `--out`; there is no atomic rename. Re-running into the same `--out` wipes lab-owned content plus `report.json`, `REPORT.md`, and `mediamanifest.json` first, preventing stale assets from lingering. Input files are never touched.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/instagram.md` | Boris Markdown (trunk stub) | Lab-generated, disposable | N/A (single file) | Boris compiler, author | Not versioned beyond schema_version field |
| `content/instagram/<kind>-<id>.md` | Boris Markdown (one per record) | Lab-generated, disposable | Deterministic by entity ID derivation strategy | Boris compiler, author | Not versioned |
| `theme/layouts/main.html` | HTML scaffold | Lab-generated | N/A | Boris compiler | Not versioned |
| `theme/layouts/footer.html` | HTML scaffold | Lab-generated | N/A | Boris compiler | Not versioned |
| `theme/assets/css/site.css` | CSS scaffold | Lab-generated | N/A | Boris compiler | Not versioned |
| `theme/assets/media/<uri-relative>` | Copied source bytes, unchanged | Lab-generated | Derived from source URI path | Author, Boris compiler | Byte-identical to source |
| `report.json` | JSON (`format: "boris-instagram-migration-lab"`, `schema_version: 1`) | Lab-generated, disposable | Field order stable; record order by processing order | Tooling, CI, author | Schema version 1; no formal stability guarantee beyond version field |
| `REPORT.md` | Markdown human summary | Lab-generated, disposable | N/A | Author | Not versioned |
| `mediamanifest.json` | JSON media audit | Lab-generated, disposable | Record order by processing order | Author, enrichment pass | Not versioned |

**Required for a minimally useful result:** `content/` Markdown pages and `report.json`. Media and theme outputs are optional for the content review workflow.

**Optional:** `theme/` scaffold files (generated but can be replaced by author), `REPORT.md` (human convenience duplicate of `report.json`), `mediamanifest.json` (media audit sidecar).

***

## Serialization and schema behavior

All machine-readable output is hand-serialized using `jsonEscapeAppend` — a custom byte-by-byte JSON string escaper declared in the file. It escapes `"`, `\`, `/`, `\r`, `\n`, and control bytes below `0x20` using `\uXXXX`. No standard-library JSON emitter is used for output; the Zig standard-library JSON *parser* (`std.json`) is used for reading input export files.

Boris frontmatter in generated Markdown uses a custom `escapeFmValue` helper that single-quotes values containing YAML-significant characters.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` | `format: "boris-instagram-migration-lab"`, `schema_version: 1` | `instagram.zig` | Field order hardcoded in emission; record order by processing sequence | Fixture integration test (presence of key fields checked) |
| `mediamanifest.json` | Not versioned separately; inherits tool context | `instagram.zig` | Record order by processing sequence | Fixture integration (partial) |
| Per-page Markdown frontmatter | Closed Boris author grammar: `id`, `title`, `parent`, `status`, `tags` | `instagram.zig` | N/A | Fixture integration |
| `REPORT.md` | Plain Markdown, no version field | `instagram.zig` | N/A | Not independently validated by test |

Field order within `report.json` objects is stable by construction (hardcoded append sequence), but this is a documentation contract, not a mechanically tested byte-stability guarantee across schema versions.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable source-record processing order | Files discovered by directory walk; sorted by path before processing | Documented contract (README); structurally consistent with other mode modules | Filesystem enumeration order on walk not independently tested for Instagram mode |
| Entity-ID derivation from durable export ID | `extractDurableId` uses longest digit run ≥10 from media URI basename; `fallbackHashId` uses FNV-1a over input parts when no durable ID found | Structurally checked (deterministic algorithm on stable input) | Hash collisions across records not tested |
| Caption encoding repair | `repairMetaEscapedUtf8` is deterministic for any given input byte sequence | Structurally checked | Mojibake detection heuristic (`hasMojibakeResidue`) is a pattern match, not a formal proof |
| Media bytes | Copied verbatim from source; no transformation | Structurally enforced | Source bytes may change between runs if dump is modified externally |
| Absence of timestamps in output | No wall-clock values in generated Markdown or reports beyond the `creation_timestamp` from the export itself | Structurally absent | `creation_timestamp` values come from the export and are included as provenance, not generation timestamps |
| No random identifiers | `fallbackHashId` is deterministic FNV-1a, not random | Structurally checked | Two distinct record sets could produce the same FNV-1a hash (collision not tested) |
| Byte-for-byte repeated-run identity | Structurally implied by the above properties combined with deterministic sort | Uncertain for Instagram mode specifically — `main.zig` comment notes Instagram tests excluded from `refAllDecls` due to allocator leak; no explicit repeated-run byte-comparison test found for this mode | No confirmed golden-comparison test for Instagram |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Media URI path traversal (read) | `isSafeMediaUri`: rejects empty, absolute (`/`), `..` component, `\`, Windows drive prefix (`X:`) | Yes — check runs before any `openFile` on media | `fixtures/hostile-instagram/` fixture; integration test exercises it | Multi-hop encoded traversal (`%2e%2e`) not confirmed as tested |
| Output escaping dump root (write) | All writes rooted at opened output-directory handle passed through `writeBytes`/`ensureParent` | Structurally enforced by directory-handle API | Partial | No separate path-containment test for output side |
| `--dump == --out` | String equality check in `main.zig` before calling `run` | Yes (main.zig) | `parseOptions` tests (indirect) | Prefix containment not checked — a dump inside `--out` or vice versa is not caught if paths merely share a prefix |
| Stale output from previous run | Output directory wiped (lab-owned content + reports) before new write | Documented contract | Not independently tested for Instagram mode | Partial write followed by failure leaves incomplete output; no rollback |
| Symlink traversal | Not addressed in `isSafeMediaUri`; no explicit symlink resolution or rejection | Not mechanically enforced | Not confirmed | Symlinks in dump tree could be followed |
| Accidental recursion into own output | `--dump != --out` check; separate directory handles | Enforced structurally | Partial | Prefix-containment gap noted above |
| Temporary files | None used; writes go directly to final output paths | N/A | N/A | Non-atomic: a crash mid-write leaves a partial file at the final path |
| Permissions / unreadable files | Standard Zig `openFile` error propagated; run returns `error.IoFailure` → exit 3 | Propagated | Not independently tested | No recovery for partial reads |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const` string | Format identity string embedded in all output | — | `"boris-instagram-migration-lab"` | Static |
| `schema_version` | `pub const u32` | Machine-readable schema version embedded in `report.json` | — | `1` | Static |
| `tool_version` | `pub const` string | Tool version string embedded in provenance comments and report | — | `"0.1.0"` | Static |
| `RunOptions` | `pub const struct` | Configuration passed from `main.zig` | `dumpdir`, `outdir`, `quiet` | Struct value | Caller-owned |
| `ConversionClass` | `pub const enum` | Per-record conversion quality classification | — | `exact`, `transformed`, `unsupported`, `humanreview` | Static |
| `MediaItem` | `pub const struct` | One media item within a record | `uri`, `creation_timestamp`, `title`, encoding flags, `theme_rel` | Struct value | Arena-owned |
| `RecordKind` | `pub const enum` | Export record kind | — | `post`, `reel`, `story`, `other`, `unknown` | Static |
| `IgRecord` | `pub const struct` | Fully resolved Instagram record ready for Markdown emission | All parsed fields | Struct value | Arena-owned |
| `MediaManifestEntry` | `pub const struct` | One entry in `mediamanifest.json` | `entity_id`, `source_uri`, `theme_asset`, `status`, `kind`, `creation_timestamp` | Struct value | Arena-owned |
| `PageRecord` | `pub const struct` | One entry in `report.json` pages/humanreview/unsupported arrays | Per-record metadata | Struct value | Arena-owned |
| `Report` | `pub const struct` | Aggregate report holding all output records | All processed records | Struct value | Arena-owned |
| `isSafeMediaUri` | `pub fn` | Path-traversal safety gate for media URIs | `uri: []const u8` | `bool` | Stateless |
| `extractDurableId` | `pub fn` | Derives a stable export ID from a media URI using longest digit run ≥10 | `uri: []const u8` | `?[]const u8` (slice of input) | Borrow of caller's data |
| `fallbackHashId` | `pub fn` | FNV-1a hash-based ID fallback when no durable digit run found | `allocator`, `parts: []const []const u8` | `![]u8` (allocated hex string) | Caller owns returned slice |
| `firstLineTitle` | `pub fn` | Derives a page title from the first non-empty caption line, capped at `max_len` with UTF-8 boundary awareness | `caption`, `max_len` | `[]const u8` (slice of caption) | Borrow |
| `escapeFmValue` | `pub fn` | YAML-safe frontmatter value quoting | `allocator`, `value` | `![]u8` | Caller owns |
| `TextRepair` | `pub const struct` | Result of `repairMetaEscapedUtf8`: repaired text, `repaired` flag, `residue` (mojibake survives) | — | Struct | Arena or caller depending on path |
| `repairMetaEscapedUtf8` | Inferred `fn` | Repairs Meta's Latin-1-as-escaped-Unicode caption encoding | `allocator`, `input` | `TextRepair` | Caller owns `text` if `repaired` |
| `parseHtmlPostsFile` | `fn` | Parses an HTML-format posts file, splitting on block boundaries | `retain`, `gpa`, `html`, `source_path`, `kind`, out list | Appends to `IgRecord` list | Arena-owned appended items |
| `parseMediaObject` | `fn` | Parses one JSON media object into `MediaItem` | `retain`, `std.json.Value` | `!MediaItem` | Arena-owned strings |
| `parseRecordObject` | `fn` | Parses one JSON record object into `IgRecord` | `retain`, `std.json.Value`, `kind`, `source_path`, `index` | `!IgRecord` | Arena-owned |
| `copyFileRel` | `fn` | Copies a file by relative paths between two open directory handles | `io`, src dir+rel, dst dir+rel | Writes dst file | Temporary page-allocator buffer freed on return |
| `jsonEscapeAppend` | `fn` | Appends a JSON-escaped string to an `ArrayList(u8)` | `buf`, `gpa`, `s` | Mutates buf | Caller owns buf |
| `run` | `pub fn` | Main pipeline: parse → build records → emit Markdown + media + theme + reports | `io: std.Io`, `gpa: std.mem.Allocator`, `opts: RunOptions` | `!void`; writes all output artifacts | Arena freed on return; gpa used for long-lived collections |

`run` is the sole public entry point callable by `main.zig`. It initializes an arena allocator over `gpa`, opens the dump and output directory handles, discovers and parses records, emits all output, serializes reports, and returns. Cleanup of the arena is deferred unconditionally.

***

## Ownership and lifetime model

- **GPA (`gpa: std.mem.Allocator`):** passed in from `main.zig`; owns long-lived collections (record lists, report arrays) that must outlive the arena.
- **Arena (`arenastate: std.heap.ArenaAllocator.init(gpa)`):** initialized at the top of `run`, deferred `deinit`. Owns all parsed string slices from the JSON tree, intermediate path buffers, and per-record text that does not need to outlive `run`. The `retain` allocator alias refers to this arena.
- **`copyFileRel`:** uses `std.heap.page_allocator` as a temporary allocator for the copy buffer; freed immediately via `defer` — not arena or GPA.
- **JSON parsed values (`std.json.parseFromSlice`):** arena-allocated; freed when arena is deiniited.
- **Output file handles:** opened, written, and closed within their respective emit functions. No long-lived open handles held across record processing.
- **Argument slices:** owned by the `cold` arena in `main.zig`; passed as `const []u8` slices to `RunOptions`; borrowed by `instagram.zig` for the duration of `run`.

The `main.zig` comment explicitly notes: *"Do not refAllDecls Instagram here — its in-module tests currently leak under the testing allocator."* This indicates a known allocation path in the module's test or implementation that does not satisfy the testing allocator's leak-freedom requirement. The leak has not been publicly identified as isolated to tests only.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--dump` not provided in instagram mode | `main.zig` dispatch | Stderr: `instagram mode requires --dumpDIR`; usage printed | Exit 2 | None — run not started |
| `--dump == --out` | `main.zig` before `instagram.run` | Stderr: `--out must differ from --dump` | Exit 2 | None |
| Unknown CLI flag | `parseOptions` | Stderr: `unknown argument — try --help` | Exit 2 | None |
| Invalid `--mode` value | `parseOptions` | Stderr: `invalid flag value — try --help` | Exit 2 | None |
| Dump directory not found / unreadable | `Io.Dir.cwd.openDir` in `run` | Propagated Zig error → `main.zig` logs `errorName` | Exit 3 | None — run fails early |
| Output directory creation failure | `ensureParent` / `root.createDirPath` | Propagated → exit 3 | Exit 3 | Partial — some files may have been written |
| Unreadable source JSON/HTML file | `readFileAlloc` error propagated | Exit 3 | Exit 3 | Partial output risk |
| Unsafe media URI (traversal, absolute, backslash, drive prefix) | `isSafeMediaUri` in `run` | Record classified `humanreview`; logged in report as `unsafe media uri rejected`; run continues | No exit — non-fatal per-record | None — record still emitted as humanreview |
| Mojibake in caption, repairable | `repairMetaEscapedUtf8` | Page marked `meta-latin1-repaired` in provenance | No exit | None |
| Mojibake residue (unrepaired) | `repairMetaEscapedUtf8` | Page marked `suspected-mojibake-unrepaired`; classified `humanreview` | No exit | None |
| Write failure mid-output | `writeBytes` propagates error | Exit 3 after `main.zig` catches | Exit 3 | Partial output left in `--out` |
| Allocation failure | `std.mem.Allocator` error | Propagated as `error.OutOfMemory` → exit 3 | Exit 3 | Partial output possible |

Diagnostics are plain stderr messages via `std.log.err` in `main.zig`; no structured diagnostic format for runtime errors. Per-record anomalies (unsafe URIs, encoding issues) are structured into `report.json` / `humanreview` arrays rather than stderr.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Caller; imports this module and calls `run` | `main.zig` → `instagram.zig` | `main.zig` owns CLI dispatch |
| `tools/migration-lab/build.zig` | Build integration; compiles this file as part of `boris-migration-lab` | Build system → source | Build file is authoritative for compile config |
| `tools/migration-lab/build.zig.zon` | Dependency manifest for standalone build | Build system dependency | Authoritative for external deps (none confirmed for this module) |
| `tools/migration-lab/README.md` | Documents Instagram mode CLI, I/O, safety rules, fixture | Documentation | Informational; source code is higher authority |
| `tools/migration-lab/fixtures/mini-instagram/` | Synthetic test fixture | Test input → module | Fixture README documents coverage intent |
| `tools/migration-lab/fixtures/hostile-instagram/` | Adversarial path-traversal fixture | Test input → module | Source of traversal rejection evidence |
| `docs/MIGRATION.md` | Author guide referencing the lab | Documentation | Informational for human authors |
| `tools/migration-lab/archaeology.zig` | Sibling mode module | Peer (not imported by instagram.zig) | Independent; shares build target |
| Root `build.zig` | No relationship | None | Root build does not include this tool |
| `boris` product binary | No runtime dependency | None | Explicitly excluded |


***

## Security and trust boundaries

The dump directory is untrusted input. `instagram.zig` makes the following explicit security decisions:

- **Media URI path traversal (read side):** `isSafeMediaUri` rejects URIs containing `..` as a path component, `/` as first character (absolute), `\` (Windows separator), or a two-character drive prefix followed by `:`. This is mechanically enforced before any filesystem read of media. Percent-encoded traversal (`%2e%2e`) is **not** decoded before this check; whether Meta exports use percent-encoding in paths is not addressed by the implementation, and this represents a residual gap.
- **Caption bytes and Markdown fence safety:** caption bytes are preserved verbatim inside a fenced code block whose fence delimiter is sized to outrank the longest backtick run found in the caption itself. This prevents caption text from escaping the fence and becoming live Markdown. This is a structural safety guarantee, not a documentation claim.
- **Embedded frontmatter in packed documents:** the Boris migration provenance comment is written as an HTML comment (`<!-- boris-migration-provenance ... -->`), not as frontmatter. The frontmatter block is closed before the body; there is no mechanism by which caption content can inject into frontmatter fields.
- **Symlink traversal in dump tree:** not addressed. If the dump tree contains symlinks pointing outside the dump root, and a media URI resolves through a symlink, the `isSafeMediaUri` check on the URI string will pass (the string itself may be safe), but the resulting `openFile` call may follow the symlink. This is a residual gap.
- **Output-root containment:** all write calls use directory handles rooted at the opened output directory. String-level `--dump != --out` is checked but prefix containment is not, leaving a gap for a dump nested inside `--out` or vice versa.
- **Resource exhaustion / very large files:** `readFileAlloc` with `.unlimited` is used for both input JSON and media copies. An adversarially large file in the dump tree will be fully read into memory. There is no per-file or total-memory cap.
- **Maliciously chosen filenames in dump:** the entity-ID derivation (`extractDurableId`, `fallbackHashId`) and output path construction sanitize ID bytes for use as path components, but the full scope of output-path sanitization for arbitrary dump-provided filenames is not independently unit-tested.
- **Terminal output:** error and progress messages are written via `std.log.err` and (implicitly) `std.debug.print`; no ANSI escape sequences are emitted from caption content because captions go only into file output, not terminal output.
- **Network exfiltration:** structurally absent. No socket, HTTP, or DNS call is present in the implementation.

***

## Evidence limitations

- The Instagram fixture integration test is documented as present but its exact pass/fail assertions on `report.json` field values were not extracted from the available source evidence; only the mini-instagram fixture README and the module source were inspected. The test body for the Instagram fixture run was not found in the portions of `main.zig` extracted into the source bundle (the `main.zig` test block comments out `refAllDecls` for Instagram explicitly, and the Instagram fixture test body was not present in the recovered text).
- The `run` function body of `instagram.zig` was recovered through the source bundle in significant fragments. The complete emit logic for per-page Markdown, the theme scaffold generation, and the stale-output deletion logic were described in the README and module-level doc comment but the full implementation lines were not exhaustively recovered. Claims about emit behavior are based on the model structs, the README, the fixture README, and partial source fragments.
- Specific field names in `report.json` output beyond those visible in struct declarations and the README's schema note are uncertain.
- Whether `mediamanifest.json` carries a `schema_version` field of its own or only inherits context from the tool is uncertain.
- The `fixtures/hostile-instagram/` fixture contents were referenced but not fully inspected; the specific adversarial cases it covers beyond path traversal are uncertain.
- Cross-platform (Windows) behavior is not confirmed by any CI evidence in the inspected material.
- Percent-encoded traversal handling is uncertain.
- Whether the allocator leak acknowledged in `main.zig` is in the test harness or in production code paths is unresolved.

***

## Final source assessment

`tools/migration-lab/instagram.zig` is a self-contained implementation module providing the full Instagram Takeout conversion pipeline for the `boris-migration-lab` standalone developer tool. Its primary responsibility is: read a Meta export, parse records, repair encoding, check media-URI safety, emit Boris-compatible Markdown pages and media copies, and produce machine and human reports — all without touching the source dump or the Boris product compiler.

The **strongest supported guarantees** are: the dump is never written to (structurally enforced by directory handle separation and no write call on the dump handle); media URIs containing `..`, absolute paths, backslashes, or drive prefixes are rejected before any filesystem read (structurally enforced by `isSafeMediaUri`); caption content cannot escape a Markdown fence into live document structure (structurally enforced by fence-sizing logic); no network access or subprocess invocation is present.

The **weakest or least-tested boundaries** are: repeated-run byte identity for Instagram mode (not confirmed by a dedicated test); allocator leak under testing allocator (explicitly acknowledged, source unresolved); symlink traversal in the dump tree (not addressed); percent-encoded path traversal (not addressed); prefix-containment check for `--dump`/`--out` relationship (not implemented).

The **separation from Boris product runtime** is complete and architectural: separate `build.zig`, separate binary, no import from the product compiler graph, no involvement in HTML publication, no IR generation.

The **quality of available evidence** is moderate: the model types, safety logic, fixture structure, and README are well-recovered; the full `run` function body and exact test assertions were only partially recovered from the source bundle, leaving some behavioral details uncertain.

The **most important unresolved question** is whether the allocator leak acknowledged in `main.zig` affects production execution paths (the `run` function itself) or is isolated to the test harness, and whether fixing it would reveal a correctness issue in the arena or GPA ownership model.
