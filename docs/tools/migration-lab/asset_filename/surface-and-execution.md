---
title: "`tools/migration-lab/asset_filename.zig` surface and execution"
id: docs/tools/migration-lab/asset_filename/surface-and-execution
parent: docs/tools/migration-lab/asset_filename
status: draft
tags: [boris, zig, tools, surface, migration-lab, asset_filename]
---

# `tools/migration-lab/asset_filename.zig` surface and execution

## CLI surface

The CLI is parsed entirely in `tools/migration-lab/main.zig`. This module receives an already-resolved `Options` struct; it does not parse arguments directly. The arguments relevant to this mode are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode=asset-filename` | No (default is `astro`) | `astro` | `asset-filename`, `assets`, `asset-compat`, `filename-compat` | Selects this operating mode | Unknown mode → usage error, exit 2 |
| `--root=DIR` | No | `.` | Any directory path | Content tree root (read-only source) | Inaccessible root → `SourceNotFound` / exit 3 |
| `--out=DIR` | No | `migration-report` | Any directory path differing from `--root` | Output directory for all generated artifacts | Out == source → `OutputInsideSource` / exit 3 |
| `-q`, `--quiet` | No | off | flag | Suppress progress lines to stderr | — |
| `-h`, `--help` | No | — | flag | Print usage; exit 0 | — |

**Exit codes** (from README; exact codes enforced in `main.zig`, not this file): `0` success, `2` usage error, `3` I/O error. Exit code assignment is uncertain for `Collision` and `OutputInsideSource` errors — they map to exit 3 by README convention but exact mapping in `main.zig` was not inspected directly.

Mutually incompatible options, unknown arguments, and missing values for flags that require arguments are handled in `main.zig`; behavior of this module for those cases is not applicable (it receives pre-validated options).

***

## Inputs and discovery model

The module discovers its inputs through a deterministic filesystem walk. The content root is resolved as follows: if `--root/content` exists as a directory, that subdirectory is used as the content root; otherwise `--root` itself is used directly.

Pages are any `.md` or `.mdx` files found by recursive descent from the content root. Asset directories are any `{stem}.assets/` directories that are siblings of a discovered Markdown page in the same directory (same parent, name = `{stem}.assets` where `{stem}` equals the page filename without extension).


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Markdown pages | Recursive walk of content root; files ending `.md` or `.mdx` | Yes | `.git`, `node_modules`, `dist`, `.boris`, `zig-cache`, `zig-out`, `.obsidian` (via `isSkipDir`) | Implemented in `PageEntry` discovery loop |
| Sibling `.assets/` directories | Directory entries matching `{stem}.assets` adjacent to each discovered page | Yes (when present) | None beyond skip-dir rules | Implemented in `collectAssets` style walk |
| Files within `.assets/` trees | Recursive walk of each `{stem}.assets/` directory | Yes | Same skip-dir list | Per-file record created for each entry |
| Symlinked entries | Detected via `isSymlink()` using `dir.readLink` | Rejected | All symlinks → `rejected` record | Implemented; symlink check before open |
| Files outside `.assets/` subdirectories | Not treated as assets | No | — | Only `.assets/`-rooted paths are processed as assets |
| Files with Boris-safe names | Discovered normally | Yes; `action: unchanged` | — | `isBorisSafeWithinTree` check |
| `--out` directory and its children | Excluded from source discovery | No | Enforced by `refuseOutputInsideSource` | Implemented |

**Path ordering:** discovered paths are sorted lexicographically (ascending) before processing. This is the mechanism relied upon for deterministic first-path-wins collision resolution.

**Symlink handling:** `isSymlink()` uses `dir.readLink` as a positive signal. Whether this correctly detects all symlink forms on all host platforms is uncertain; it is documented as a rejection policy but not tested with a committed symlink fixture (the README mentions a symlink in `hostile-asset-filenames/` but a committed symlink in a git repository is unusual and its presence is uncertain).

**Tracked vs ignored files:** The tool reads whatever files are present on the filesystem under `--root`; it does not consult `.gitignore` or any VCS tracking state.

***

## Output artifact model

All outputs are written to the configured `--out` directory. The module does not use temporary or staging directories; it writes directly to the output paths. There is no explicit stale-output cleanup (unlike the WordPress mode, which wipes `content/` before re-running); a second run overwrites files with identical content (idempotent for identical-bytes collisions) but does not delete previously generated outputs that no longer correspond to inputs.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/<page-path>.md` or `.mdx` | Markdown (rewritten or copied verbatim) | Tool-generated | Lexicographic by page path | Boris product compiler (after human review) | Not versioned; byte-stable on repeated runs for same input |
| `content/<page-stem>.assets/<sanitized-name>` | Binary asset bytes (verbatim copy) | Tool-generated | Lexicographic by source path | Boris product compiler | Byte-identical to source |
| `asset_filename_manifest.json` | JSON; format `boris-asset-filename-lab`; schema 1 | Tool-generated | Records sorted by source_path | Human review, automated analysis | Schema version 1; field order fixed in serialization code |
| `rewrite_manifest.json` | JSON | Tool-generated | Records sorted by page_path then original_dest | Human review | No explicit schema version in evidence reviewed |
| `report.json` | JSON | Tool-generated | Fixed top-level field order | Human review | Schema version inherited from lab; not separately versioned |
| `REPORT.md` | Markdown human summary | Tool-generated | N/A | Human review | Not a stable machine format |

**Canonical machine records:** `asset_filename_manifest.json` is the authoritative per-asset provenance record, carrying original path, destination path, action, reason, and SHA-256. `rewrite_manifest.json` is the authoritative per-rewrite Markdown destination record.

**Generated and disposable:** All outputs are generated and disposable — the source tree is the authoritative input. The manifests are not prerequisites for any other build step.

**Required for a minimally useful result:** `content/**` (sanitized pages and assets) plus `asset_filename_manifest.json` constitute the minimal useful output. `rewrite_manifest.json` and `report.json`/`REPORT.md` are useful for human review but not required for the sanitized content to be functional.

**Optional:** `REPORT.md` is a human convenience; `rewrite_manifest.json` may be empty if no rewrites were needed.

***

## Serialization and schema behavior

The module serializes JSON using hand-written append logic (`appendJson`, `appendUsize`, `appendBool`). It does not use Zig's `std.json` emitter.

**`asset_filename_manifest.json`:**

- Top-level fields in fixed order: `format`, `schema_version`, `policy`, `entries`.
- `format` value: `"boris-asset-filename-lab"`.
- `schema_version` value: `1`.
- `policy`: a fixed human-readable string literal describing the safety contract.
- `entries`: JSON array; one object per discovered asset.
- Per-entry fields in fixed order: `source_path`, `page_stem`, `within_tree_source`, `within_tree_dest`, `dest_path`, `action`, `reason`, `sha256_hex`, `bytes`.
- `action` values: `"unchanged"`, `"rewritten"`, `"rejected"`.
- `sha256_hex`: lowercase hex SHA-256 of the source file bytes; empty string `""` for rejected entries.
- Path representation: `/`-separated, content-root-relative.
- Records sorted by `source_path` ascending.
- Terminated with a final newline.

**`rewrite_manifest.json`:**

- Similar hand-serialized JSON.
- Per-entry fields: `page_path`, `original_dest`, `rewritten_dest`, `reason`.
- Records sorted by `page_path` then `original_dest`.
- No explicit schema version field was confirmed in the evidence reviewed; this is uncertain.

**JSON escaping:** The `appendJson` function escapes `"`, `\`, `\n`, `\r`, `\t`, and control characters below `0x20` using `\uXXXX` notation. High bytes (>= 0x80, i.e., UTF-8 multi-byte sequences in source paths) are written as literal bytes without escaping, which is valid JSON for UTF-8 content but relies on the path bytes being valid UTF-8 for strict JSON parsers.

**Newline policy:** Files are terminated with a single `\n`. Internal records are newline-separated in the JSON array.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `asset_filename_manifest.json` | `boris-asset-filename-lab` / schema 1 | This file | `source_path` ascending | Tested via hostile fixture; `schema_version` field present |
| `rewrite_manifest.json` | Not versioned (uncertain) | This file | `page_path`, `original_dest` | Tested via fixture (content spot-checked) |
| `report.json` | Not separately versioned | This file | Fixed field order | Spot-checked in fixture tests |
| `REPORT.md` | N/A | This file | N/A | Not mechanically compared |


***

## Determinism and reproducibility

The module's documented contract is that repeated runs on the same input produce byte-identical output. The mechanisms supporting this are:


| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable discovery order | Lexicographic sort of discovered paths before processing | Structurally checked (sort is in code) | Filesystem enumeration order affects sort input before sort; on most host filesystems this is stable for a given tree but is not guaranteed across filesystems |
| Stable collision resolution | First source path in lexicographic order wins; subsequent paths with same sanitized destination are rejected | Structurally checked | Only as stable as the sort |
| No timestamps in output | No `std.time` calls visible in the serialization paths; no host timestamp fields in any manifest | Structurally checked (code inspection) | No explicit test asserting timestamp absence |
| No random identifiers | No `std.rand` usage visible in this module | Structurally checked | — |
| No absolute paths in output | All output paths are content-root-relative | Structurally checked | Depends on correct relativization; tested implicitly by fixture |
| Byte-identical repeated runs | Two-run comparison of `asset_filename_manifest.json` in hostile fixture test | Directly demonstrated | Demonstrated only for the hostile fixture on the test host; not cross-platform |
| Stable sanitization function | `sanitizeSegment` is a deterministic pure function of input bytes | Structurally checked | No property-based testing across all byte sequences |
| Fixed JSON field order | Hand-serialized; field order is literal in code | Structurally checked | — |

No cross-platform byte identity is claimed or tested. Map iteration order (for the case-collision map) depends on `std.StringHashMapUnmanaged` iteration order, which may not be stable across Zig versions or platforms. This is a residual non-determinism risk for collision records in manifests.

***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into source tree | `refuseOutputInsideSource` check at entry | Yes (returns error before any write) | Indirectly (run succeeds only when out ≠ root) | Relies on string prefix comparison; may be bypassed by symlinks at the directory level |
| Source file modification | No write calls target source dir | Yes (structurally) | Yes (source immutability assertions in fixture tests) | — |
| Path traversal via asset filename `..` | `sanitizeWithinTree` folds `..` and `.` segments to `"asset"` | Yes (sanitization in code) | Yes (hostile fixture includes traversal cases) | Traversal in Markdown image references is detected and left unrewritten for human review |
| Symlink traversal | `isSymlink()` check before reading asset | Implemented | Documented in hostile fixture; direct symlink test uncertain | `isSymlink` uses `readLink` which may not detect all symlink forms; committed symlink in fixture repository is uncertain |
| Destination collision (exact) | Check for existing file before write; error on byte mismatch | Yes | Yes (hostile fixture) | Idempotent only for byte-identical content; no atomic write |
| Destination collision (case-fold) | ASCII case-fold map tracks seen destinations; first path wins | Yes | Yes (hostile fixture includes case collision) | ASCII case-fold only; does not account for Unicode case normalization on case-insensitive filesystems |
| Accidental recursion into own output | `refuseOutputInsideSource` prevents `--out` inside `--root` | Yes | Indirectly | Does not prevent `--root` inside a previously generated `--out` |
| Very large files | No size check before `allocRemaining(.unlimited)` | No | Not tested | Allocation failure on very large asset files |
| Output overwrite without atomic replace | Direct `writeFile` without staging | Not enforced | Not tested | A failed mid-run could leave partial output; previous valid output may be partially replaced |
| Stale output from prior run | No cleanup of prior `--out` content | Not enforced | Not tested | Re-running after removing some source assets may leave orphaned output files |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const []const u8` | Machine-readable tool identifier (`"boris-asset-filename-lab"`) | — | Embedded in manifests | Static string literal |
| `schema_version` | `pub const u32` | Manifest schema version (`1`) | — | Embedded in manifests | Static |
| `tool_version` | `pub const []const u8` | Tool version string (`"0.1.0"`) | — | Embedded in manifests/reports | Static |
| `Options` | `pub const struct` | Input configuration for `run` | `root_dir`, `out_dir`, `quiet` | Passed to `run` | Owned by caller |
| `LabError` | `pub const error set` | Module-specific error values | — | Returned from `run` and helpers | — |
| `isBorisSafeWithinTree` | `pub fn ([]const u8) bool` | Path grammar validator (mirrors Boris core) | Within-tree path string | `true` / `false` | Stateless |
| `unsafeReason` | `pub fn ([]const u8) []const u8` | Classify why a path fails Boris grammar | Path string | One of: `"empty"`, `"absolute"`, `"backslash"`, `"empty_segment"`, `"traversal"`, `"spaces"`, `"percent_encoding"`, `"unicode"`, `"unsafe_chars"`, `"unsafe"` | Stateless; returns string literal |
| `urlDecodeAlloc` | `pub fn (allocator, []const u8) ![]u8` | Decode `%XX` percent-encoding; invalid sequences pass through literal | Allocator + encoded segment | Decoded bytes (caller owns) | Caller frees |
| `sanitizeSegment` | `pub fn (allocator, []const u8) ![]u8` | URL-decode then sanitize one path segment | Allocator + segment | Boris-safe segment (caller owns) | Caller frees |
| `sanitizeWithinTree` | `pub fn (allocator, []const u8) ![]u8` | Sanitize a multi-segment within-tree path | Allocator + path | Boris-safe path (caller owns) | Caller frees |
| `asciiLowerAlloc` | `pub fn (allocator, []const u8) ![]u8` | ASCII lowercase for collision key construction | Allocator + string | Lowercased bytes (caller owns) | Caller frees |
| `AssetAction` | `pub const enum` | `unchanged` / `rewritten` / `rejected` | — | Used in `AssetRecord` and manifest | — |
| `AssetRecord` | `pub const struct` | Per-asset manifest row | — | Fields: source_path, within_tree_source, page_stem, within_tree_dest, dest_path, action, reason, sha256_hex, bytes | Owned by arena during run |
| `RewriteRecord` | `pub const struct` | Per-rewrite manifest row | — | Fields: page_path, original_dest, rewritten_dest, reason | Owned by arena during run |
| `RejectRecord` | `pub const struct` | Per-rejection report row | — | Fields: source_path, reason, detail | Owned by arena during run |
| `refuseOutputInsideSource` | `pub fn ([]const u8, []const u8) !void` | Guard against out-inside-source misconfiguration | source path, out path | `error.OutputInsideSource` or nothing | Stateless |
| `run` | `pub fn (io, allocator, options) !void` | Main entry point for the mode | `Io`, allocator, `Options` | Produces all output artifacts; returns error on failure | Owns all intermediate allocations; caller owns nothing after return |
| `pageStemFromName` | `fn` (private) | Extract stem from `.md`/`.mdx` name | Filename | `?[]const u8` | Stateless |
| `PageEntry` | `const struct` (private) | Discovered page record | path, stem, asset_root | — | Arena lifetime |
| `isSymlink` | `fn` (private) | Symlink detection via `readLink` | `Io`, dir, rel path | `bool` | Stateless |
| `sha256Hex` | `fn` (private) | Compute lowercase hex SHA-256 | Allocator, bytes | 64-byte hex string | Caller frees |
| `appendJson` / `appendUsize` / `appendBool` | `fn` (private) | JSON serialization helpers | Buffer, allocator, value | Appends to buffer | Buffer owned by caller |

**`run` function responsibilities:**

1. Call `refuseOutputInsideSource` as a preflight guard.
2. Open the source root (`--root` or `--root/content` if present).
3. Walk the source tree to collect `PageEntry` records; sort lexicographically.
4. For each page, walk its sibling `.assets/` directory to collect asset entries.
5. For each asset: check if Boris-safe (if so, `unchanged`); else sanitize the within-tree path segment-by-segment; check for case-collision; check for symlink; read bytes; compute SHA-256; write to `--out` destination.
6. For each Markdown page: rewrite image and link destinations in the body where the original matches a sanitized mapping (longest-match first, fence-aware).
7. Write rewritten (or verbatim) Markdown pages to `--out/content/`.
8. Serialize and write `asset_filename_manifest.json`, `rewrite_manifest.json`, `report.json`, `REPORT.md`.
9. Return `void` on success or the first encountered error.

***

## Ownership and lifetime model

The `run` function receives a single `allocator` (passed from `main.zig`, which uses a GPA or arena). All intermediate allocations — page lists, asset records, sanitized path strings, file body buffers, manifest serialization buffers — are allocated from this allocator. There is no separate arena per page or per asset in the evidence reviewed; all allocations share the caller-provided allocator.


| Resource | Owner | Freed on success | Freed on error |
| :-- | :-- | :-- | :-- |
| `PageEntry` list and strings | `allocator` | At end of `run` (or not freed if caller frees whole arena) | Propagated error; caller responsible |
| Source file body buffers | `allocator` | After Markdown rewrite; freed per-file with `defer` | `defer` fires on scope exit |
| Sanitized path strings (within-tree, dest) | `allocator` | Retained in `AssetRecord` until manifest emit | Leaked on early return unless errdefer used |
| `AssetRecord` / `RewriteRecord` arrays | `allocator` | After manifest serialization | Uncertain |
| Manifest serialization buffers | `allocator` | After `writeBytes` | `errdefer buf.deinit` |
| Source file handles | Stack (defer close) | Immediately after read | `defer file.close` |
| Output file handles | Stack (via `writeFile`) | After write | On error from `writeFile` |

**Leak freedom** is not confirmed by allocator-checking tests in the available evidence. The tool is invoked as a single-run process; any leaks are reclaimed by process exit.

**Lifetime assumptions enforced by convention (not mechanically):** `AssetRecord.source_path` slices may point into the page-discovery allocations; if those are freed before manifest serialization, use-after-free would occur. Whether these are duped or sliced depends on implementation details not fully confirmed in the reviewed evidence.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--out` same as or inside `--root` | `refuseOutputInsideSource` at `run` entry | Error message to stderr (via `main.zig`) | Exit 3 | None (no writes yet) |
| Source root not accessible | `openDir` on source root | I/O error message | Exit 3 | None |
| Unreadable asset file | `readFileAlloc` | Record as `rejected`; run may continue | Exit 0 (uncertain) | Partial manifest |
| Symlink detected | `isSymlink` before open | Record as `rejected("symlink")`; run continues | Exit 0 | Partial content |
| Destination collision | Collision map check | Record as `rejected("collision")`; run continues | Exit 0 (uncertain) or Exit 3 if fatal | Partial content |
| Output write failure | `writeBytes` call | I/O error propagated | Exit 3 | Partial `--out` tree |
| Allocation failure | Any `allocator` call | OOM error propagated | Exit 3 | Partial `--out` tree |
| Malformed `--mode` or `--out` | `main.zig` argument parsing | Usage message to stderr | Exit 2 | None |

The distinction between collision-as-recorded-warning vs. collision-as-fatal-error is **uncertain** from the evidence reviewed. The `LabError.Collision` error value exists, but whether `run` returns it or only records it in the manifest is not confirmed.

No structured diagnostic format (e.g., JSON error output) is emitted; all user-visible error messages are plain stderr strings written by `main.zig`.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Dispatch site; parses CLI and calls `run` | Caller → this file | `main.zig` is authoritative for CLI surface |
| `tools/migration-lab/build.zig` | Compiles this file into `boris-migration-lab` | Build configuration | `build.zig` determines executable name and test step |
| `tools/migration-lab/README.md` | Documents mode behavior, safety rules, output format, CLI flags | Documentation | README is evidence to verify; implementation is authoritative |
| `docs/contracts/content-local-assets.md` | Normative Boris path grammar that this file mirrors locally | Input contract | Boris contract is authoritative; this file derives from it |
| `fixtures/hostile-asset-filenames/` | Test fixture for hostile input coverage | Test input | Fixture is test evidence; not normative |
| `fixtures/image-path-starlight/` (F-L1) | Test fixture for image-path migration (Starlight mode; shared policy) | Test input | Partial coverage of same migration policies |
| `tools/migration-lab/starlight.zig` | Sibling module; shares some image-migration policy concepts (`isBorisSafeWithinTree` mirrored there) | Sibling implementation | Independent; no import relationship |
| Root `build.zig` | No relationship | None | — |
| `src/` (Boris product compiler) | Explicitly excluded; grammar mirrored without import | None | Boris `src/` is authoritative for the grammar contract |


***

## Security and trust boundaries

**Input trust model:** The source content tree is untrusted archival data. The tool reads it as opaque bytes for asset copying and as Markdown text for destination rewriting. The following trust boundaries apply:

- **Asset file bytes:** Copied verbatim without interpretation. Malicious bytes in an asset file (e.g., a large file, a file with control characters in its content) are copied directly into the output. No content-type validation is performed beyond the filename extension being irrelevant to the copy.
- **Markdown body bytes:** Read and processed for `![...](...)`-style image and link destination extraction. The tool rewrites only `original_dest` strings it recognized during the asset collection pass; it does not parse or execute Markdown AST. An adversarial Markdown file could contain:
    - **Markdown fence escape:** The rewrite logic is documented as "fence-aware," meaning it skips rewriting destinations inside fenced code blocks. The precise fence detection implementation and its robustness to adversarial fence sequences is uncertain from the evidence reviewed.
    - **Embedded frontmatter in packed documents:** Not applicable; this mode does not pack documents into bundles.
    - **Bundle delimiters:** Not applicable.
- **Filenames:** The path grammar validation and sanitization pipeline is the primary defense against hostile filenames. Path traversal (`..`) is folded to `"asset"` in `sanitizeWithinTree`. However, the Markdown rewrite step leaves `../`-containing reference targets unrewritten for human review rather than silently dropping them.
- **Symlinks:** `isSymlink()` is called before any asset is opened. If `readLink` does not detect a symlink on a particular OS/filesystem, the file would be opened and read as a regular file.
- **Very large files:** No size cap is enforced before `allocRemaining(.unlimited)`. A very large asset file or a very large Markdown page could exhaust process memory.
- **Maliciously chosen filenames:** A filename like `\x00` or one containing null bytes would be processed by `sanitizeSegment`; null bytes would be mapped to `-` (since they are below 0x20 and not in `isSafeChar`). Whether the resulting output path is safe on the host filesystem is not tested.
- **Terminal output:** Progress output (when `--quiet` is false) includes source paths, which may contain ANSI-significant bytes. No escaping of terminal output is implemented.
- **Network exfiltration:** Absent. No network calls.
- **Output overwrite:** No atomic replacement; a failed partial write leaves the output directory in a mixed state. Running against a previous output without cleaning it first may leave stale files.

**Caller assumptions:** The caller (`main.zig`) is responsible for ensuring that `--out` is not writable by untrusted parties during a run (TOCTOU on path checks). The tool does not claim to be safe for use in shared-directory environments.

***

## Evidence limitations

- **`main.zig` not directly inspected:** The CLI argument parsing, mode dispatch, error-to-exit-code mapping, and allocator setup in `main.zig` were not reviewed directly. Claims about exit codes, argument aliases, and help output are based on the README and are uncertain where they conflict with or go beyond README documentation.
- **Full `run` function body:** The source pack includes the beginning of `asset_filename.zig` (through `sanitizeWithinTree`, helper declarations, and struct definitions) but the `run` function body, manifest serialization functions, and test declarations were retrieved via search rather than a single complete read. Some implementation details of `run` (exact collision-handling path, rewrite fence detection, stale-output behavior) are inferred from documented contract and control-flow reasoning rather than direct code inspection.
- **Symlink fixture:** The README mentions a symlink in `fixtures/hostile-asset-filenames/`. Whether this symlink is actually committed to the repository (git does not reliably track symlinks as symlinks on all platforms) is uncertain. The symlink rejection test may or may not exercise real symlink detection.
- **`rewrite_manifest.json` schema:** No explicit `schema_version` field in `rewrite_manifest.json` was confirmed. This format may be unversioned.
- **Collision fatality:** Whether `error.Collision` is returned from `run` (fatal) or only recorded in the manifest (soft) is not confirmed.
- **Cross-platform behavior:** All tests are single-platform (the test host). No CI evidence for Windows or other filesystems was reviewed.
- **`build.zig.zon` dependencies:** The `tools/migration-lab/build.zig.zon` file was not directly inspected. The claim of "Zig standard library only" is based on source code imports; external package dependencies are not confirmed absent.
- **`AGENTS.md` and `docs/STATUS.md`:** These files were not directly inspected. Claims about them are based on README and source evidence only.
- **Allocation behavior under error:** Whether `errdefer` is consistently used for all intermediate allocations in `run` is uncertain. Leak freedom is not confirmed.

***

## Final source assessment

`tools/migration-lab/asset_filename.zig` is the complete, self-contained implementation of the `--mode=asset-filename` operating mode of the `boris-migration-lab` standalone binary. Its actual responsibility is deterministic, one-way sanitization of content-local asset filenames from migration-dirty source trees into the strict Boris path grammar, with full provenance recording and source immutability guarantee.

**Strongest supported guarantees:** Source immutability (no write to source tree, verified by fixture test). Byte-identical repeated runs on the same input (directly demonstrated by two-run manifest comparison). Deterministic path sanitization (pure function; inline-tested). Symlink rejection (implemented in code; tested via fixture). Collision detection and rejection (case-fold-aware; directly tested).

**Weakest or least-tested boundaries:** Stale-output cleanup (not implemented, not tested). Behavior on interrupted or failed partial runs (no rollback, no atomic writes). Cross-platform byte identity (not tested). Symlink detection reliability across OS/filesystem variants. Collision fatality vs. soft-reject contract (uncertain from evidence reviewed). Allocation behavior on very large files (unbounded `allocRemaining`).

**Separation from Boris product runtime:** Structurally enforced. The file imports only `std`. The comment `// mirrors Boris core; do not import src/` is present in the grammar section. The lab binary is compiled from a separate `build.zig` and is explicitly excluded from the root `zig build test` gate. The Boris path grammar is re-implemented locally as a pure function without sharing code with the product compiler.

**Quality of available evidence:** Good for the core path grammar and sanitization functions (full source visible, inline tests reviewed). Partial for the `run` function body and manifest serialization (inferred from control-flow reasoning, documented contract, and fixture test assertions rather than direct full source read). Absent for `main.zig` CLI handling, `build.zig.zon` dependencies, and `AGENTS.md`.

**Most important unresolved question:** Whether a destination collision causes a fatal `error.Collision` return from `run` (aborting the run with exit 3 and a potentially partial output) or produces only a `rejected` manifest entry with the run completing successfully (exit 0). This determines whether callers can trust any output in `--out` when the manifest contains collision records, and it affects the documented safety contract in README safety rule 10.
