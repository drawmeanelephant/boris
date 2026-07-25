---
title: "`tools/migration-lab/wordpress_theme.zig` surface and execution"
id: docs/tools/migration-lab/wordpress_theme/surface-and-execution
parent: docs/tools/migration-lab/wordpress_theme
status: draft
tags: [boris, zig, tools, surface, migration-lab, wordpress_theme]
---

# `tools/migration-lab/wordpress_theme.zig` surface and execution

## CLI surface

The `wordpress-theme` mode surface is handled by `main.zig`'s `parseOptions` and dispatched to `wordpresstheme.run`. The module itself accepts an `Options` struct.


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode wordpress-theme` | No (implied by `--root` in wordpress-theme context if explicitly set) | `astro` | `wordpress-theme`, `wp-theme`, `kubrick-theme` | Selects `wordpress-theme` analysis mode | Invalid alias → `error.InvalidValue` → exit 2 |
| `--root DIR` | Yes (for this mode) | `.` | Any filesystem path | Sets theme source root; must differ from `--out` | If equal to `--out` → stderr + exit 2 |
| `--out DIR` | No | `migration-report` | Any filesystem path | Output directory (created if missing) | Creation failure → exit 3 |
| `-q` / `--quiet` | No | off | flag (no value) | Suppresses progress line to stderr | n/a |
| `-h` / `--help` | No | off | flag | Prints usage and exits 0 | n/a |

**Exit codes:** 0 success, 2 usage error, 3 I/O error. Source: `ExitCode` enum in `main.zig`; confirmed by README.

**Unknown arguments:** `error.UnknownFlag` → stderr message + usage + exit 2.

**Missing values:** `error.MissingValue` → stderr message + usage + exit 2.

**No `--root` provided:** `main.zig` does not require `--root` to be set before dispatching; the default is `.`. The `run` function will attempt `Io.Dir.cwd.openDir(opts.rootdir)` and return `error.SourceNotFound` if it fails → exit 3.

**`--root` equals `--out`:** Checked in `main.zig` before dispatch; exits with usage error 2.

**No mutually exclusive options** for this mode.

## Inputs and discovery model

The tool walks `opts.rootdir` recursively using `walkTree`. All file kinds encountered are inventoried; text files are additionally line-scanned.

**Skipped directories:** `.git`, `node_modules`, `dist`, `zig-out`, `.zig-cache`, `migration-report` — implemented in `isSkippedDir`.

**Included file kinds:**

- `.php` files: full line scan via `scanPhp` (hook/call/template detection) plus PHP-presence marker.
- `style.css` (basename match, case-insensitive): scanned via `scanStyle` for provenance fields (Theme Name, Theme URI, Author, Version, Template).
- All other `.css`, `.js`, `.mjs`, `.txt`, `.md`: classified and inventoried; `.css` files other than `style.css` are not line-scanned for provenance.
- All remaining files with asset extensions (`.png`, `.jpg`, `.jpeg`, `.gif`, `.svg`, `.webp`, `.ico`, `.woff`, `.woff2`, `.ttf`, `.otf`): classified as `asset`, hashed, inventoried.
- Other files: classified as `other`, hashed, inventoried.

**Symlink handling:** Not explicitly handled; `walkTree` uses `std.fs.Dir.iterate()`. Behavior on symlinks is not tested and is uncertain.

**Path normalization:** Paths are constructed with `joinRel` using `/` separator. No explicit absolute-path rejection within the walk (containment is enforced at the top level by `refuseOutputInsideSource` on `rootdir`/`outdir` pair).

**Source-path ordering:** `fileLess` sorts `FileRec` lexicographically by path (`std.mem.order(u8, ...)`). `signalLess` sorts signals by `(sourcepath, line, category, name)`.

**Unreadable files:** `readFileAlloc` errors are caught per-file (`catch continue`); unreadable files are silently skipped from the scan (their `FileRec` is still appended from `walkTree` before the scan loop in `run`). This means the inventory includes file metadata for unreadable files but no signals from them.

**Empty theme tree:** Produces empty arrays in JSON; no special handling or error.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| PHP templates | Walk `--root`, extension `.php` | Yes | Skipped dirs | `walkTree`, `scanPhp` |
| WordPress stylesheet | `style.css` basename (case-insensitive) | Yes | Skipped dirs | `scanStyle` |
| CSS assets | Walk `--root`, extension `.css` (not `style.css`) | Yes (inventory only) | Skipped dirs | `isAssetPath` |
| JS/MJS | Walk `--root`, `.js`/`.mjs` | Yes (inventory; decision `drop`) | Skipped dirs | `isAssetPath`, `fileDecision` |
| Image/font assets | Walk `--root`, image/font extensions | Yes | Skipped dirs | `isAssetPath` |
| Skipped directories | `isSkippedDir` name match | No | — | `walkTree` |
| Symlinks | Not explicitly handled | Uncertain | — | No test coverage |
| Generated output | `migration-report` dir name skipped | No | — | `isSkippedDir` |

## Output artifact model

All output is written to `--out` (created if missing). No temporary or staging paths are used. No previous output cleanup is performed; files are overwritten if `--out` already exists from a prior run.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `inventory.json` | Hand-rolled JSON | Generated, disposable | Files: lex path; signals: (path, line, category, name) | Human review, tooling | Not explicitly versioned beyond `schemaVersion: 1` |
| `slotmapping.json` | Hand-rolled JSON (static, hardcoded) | Generated, disposable | Fixed (hardcoded slots) | Human design review | Static content; format `boris-wordpress-theme-static-prototype`, schema 1 |
| `manualreview.json` | Hand-rolled JSON | Generated, disposable | Signal sort order | Human review | Format `boris-wordpress-theme-manual-review`, schema 1 |
| `prototypemain.html` | Static HTML (hardcoded) | Generated, disposable | Fixed | Human/design starting point | Hardcoded; not versioned |
| `report.json` | Hand-rolled JSON | Generated, disposable | Counts only; no ordering | Summary consumption | Format `boris-wordpress-theme-archaeology-lab`, schema 1 |
| `REPORT.md` | Markdown (hand-rolled) | Generated, disposable | File table: lex sort; signal list: signal sort | Human reading | Unversioned Markdown |

**Canonical machine records:** `inventory.json` (all file and signal evidence), `manualreview.json` (all unsupported/dynamic findings with source lines).

**Human convenience:** `REPORT.md` (summary table and findings list), `prototypemain.html` (static slot shell).

**Required for minimally useful output:** `inventory.json` + `manualreview.json` + `slotmapping.json` + `prototypemain.html`.

**Optional:** `report.json` (counts only), `REPORT.md` (human duplicate of counts and signal list).

**Stale-output cleanup:** Not performed. Rerunning against the same `--out` overwrites all six files deterministically. Extraneous files from a prior run are not removed.

**Atomic replacement:** Not implemented; files are written sequentially. A failure mid-run leaves partial output. No prior valid output is preserved.

## Serialization and schema behavior

All JSON is hand-rolled using `appendJson` (string escaping), `appendUsize` (integer), and `appendBool`. There is no stdlib JSON encoder in use.

**String escaping (`appendJson`):** Escapes `"` → `\"`, `\` → `\\`, newline → `\n`, carriage return → `\r`, tab → `\t`, null byte → `\u0000` via `\x04` format, and control characters below 0x20 using `\uXXXX`. Solidus (`/`) is not escaped.

**Field ordering:** Fixed within each emitter function; not configurable.

**Record ordering:** Files sorted by path (lex); signals sorted by `(sourcepath, line, category, name)` — both enforced by `std.mem.sort` before serialization.

**Path representation:** Scan-root-relative POSIX-style paths (slash-joined by `joinRel`).

**Byte counts:** Reported as the byte length of the file content as read (`data.len`).

**Digest fields:** SHA-256 as 64-character lowercase hex string, computed by `sha256Hex` over the full file content.

**Newline policy:** `\n` (Unix) throughout; `\r\n` not used.

**Empty arrays:** Emitted as `[]` (no special handling).

**Version disagreement:** No reader-side version checking; `schemaVersion` is written but not validated on read. `slotmapping.json` uses format identifier `boris-wordpress-theme-static-prototype` with `schemaVersion: 1`. `manualreview.json` uses `boris-wordpress-theme-manual-review` with `schemaVersion: 1`. `inventory.json` and `report.json` use `boris-wordpress-theme-archaeology-lab` with `schemaVersion: 1`.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `inventory.json` | `boris-wordpress-theme-archaeology-lab` / 1 | `emitInventory` | Files lex, signals (path,line,cat,name) | Substring checks in determinism test |
| `slotmapping.json` | `boris-wordpress-theme-static-prototype` / 1 | `emitSlots` (hardcoded) | Fixed | Indirectly by determinism test |
| `manualreview.json` | `boris-wordpress-theme-manual-review` / 1 | `emitManualReview` | Signal sort order | Substring checks: `wpfooter`, `wp_enqueue_script` |
| `report.json` | `boris-wordpress-theme-archaeology-lab` / 1 | `emitReport` | N/A (counts) | Indirectly by determinism test |
| `REPORT.md` | Unversioned Markdown | `emitReportMd` | File table lex, signal list signal sort | Indirectly |
| `prototypemain.html` | Hardcoded static HTML | `emitPrototype` | Fixed | Slot marker substring checks |

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| File inventory order | `std.mem.sort(FileRec, ..., fileLess)` — lex by path | Structurally checked | Filesystem enumeration order not normalized before sort; `walkTree` collects into an `ArrayList` then sorts, so the sort is unconditional |
| Signal order | `std.mem.sort(Signal, ..., signalLess)` — (path, line, cat, name) | Structurally checked | Same as above |
| Byte-identical repeated runs | Directly tested: two runs against `fixtures/mini-wordpress-kubrick`, all 6 output files compared with `expectEqualStrings` | Directly demonstrated | Only tested on one fixture; cross-platform byte identity not tested |
| No timestamps in output | No timestamp fields in any emitter | Structurally checked | Not separately tested |
| No random identifiers | No RNG calls | Structurally checked | n/a |
| No absolute paths in output | Paths are scan-root-relative from `joinRel("", name)` start | Structurally checked | `opts.rootdir` is written into `report.json`/`inventory.json` as `sourceroot`; if an absolute path is passed as `--root`, it appears verbatim there |
| SHA-256 determinism | `std.crypto.hash.sha2.Sha256.hash` over full file content | Structurally checked | Same file on a different platform should produce the same hash; not cross-platform tested |
| Slot mapping content | `emitSlots` returns a hardcoded string literal | Directly demonstrated | Not a behavioral property of the scan |
| Prototype HTML content | `emitPrototype` returns a hardcoded string literal | Directly demonstrated | n/a |

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Writing output inside source tree | `refuseOutputInsideSource(rootdir, outdir)` checks equality and prefix | Yes — returns `error.OutputInsideSource` | Helper tested directly in `themematerialize.zig` inline test; `run` calls it at entry | Prefix check uses byte-level `startsWith`; path normalization differences (trailing slash, symlink) could bypass it |
| Path traversal from filenames in output | Paths in JSON output are scan-root-relative strings constructed by `joinRel`; no path traversal construction on the output side | Structurally checked (output paths are flat relative paths) | Not directly tested | Hostile filenames with embedded `/`, `..`, or null bytes in the theme source could produce unexpected JSON strings; not validated |
| Symlink traversal in source walk | Not handled; `Dir.iterate()` behavior on symlinks is platform-dependent | No | Not tested | Unknown; could follow symlinks out of `rootdir` |
| Output directory creation failure | `Io.Dir.cwd.createDirPath(opts.outdir)` failure returns `error.IoFailure` → exit 3 | Yes | Not directly tested | n/a |
| Partial output on failure | Files are written sequentially; no atomic rename | No | Not tested | A mid-run I/O failure leaves partial output in `--out` |
| Overwrite of previous valid output | Unconditional; `writeBytes` overwrites existing files | No | Not tested | A failed run may leave a mix of new and old files if the run fails after some writes |
| Accidental recursion into own output | `isSkippedDir` skips `migration-report` by name; only effective if `--out` is a direct child named `migration-report` | Partial | Not tested | If `--out` is named differently and placed inside `--root`, `refuseOutputInsideSource` catches it only if the paths compare correctly |
| Very large files | `readFileAlloc` with `.unlimited`; no size cap | No | Not tested | Could cause OOM on very large PHP files |

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const []const u8` | Format identifier string for JSON output | — | `"boris-wordpress-theme-archaeology-lab"` | Static |
| `schema_version` | `pub const u32` | Schema version for output JSON | — | `1` | Static |
| `tool_version` | `pub const []const u8` | Tool version string | — | `"0.1.0"` | Static |
| `Options` | `pub const struct` | Input parameters for `run` | `rootdir`, `outdir`, `quiet` | — | Caller-owned slices; borrowed |
| `LabError` | `pub const error` | Error set for `run` | — | `OutputInsideSource`, `SourceNotFound`, `OutOfMemory`, `IoFailure` | — |
| `Decision` | `pub const enum` | File/signal disposition | — | `preserve`, `adapt`, `review`, `drop` | — |
| `TemplateKind` | `pub const enum` | WordPress template classification | — | `index`, `single`, `page`, `home`, … | — |
| `classifyTemplate` | `pub fn` | Classify a file path as a `TemplateKind` | `path: []const u8` | `TemplateKind` | Pure; no allocation |
| `isAssetPath` | `fn` (private) | Test if path has an asset extension | `path` | `bool` | Pure |
| `fileExtension` | `fn` (private) | Extract file extension | `path` | `[]const u8` (slice of input) | Borrows input |
| `isText` | `fn` (private) | Test if file should be line-scanned | `path` | `bool` | Pure |
| `fileDecision` | `fn` (private) | Map template kind + extension to `Decision` | `path` | `Decision` | Pure |
| `isSkippedDir` | `fn` (private) | Check if a directory name should be skipped | `name` | `bool` | Pure |
| `joinRel` | `fn` (private) | Join relative path segments | `allocator`, `dir`, `name` | `![]u8` (allocated) | Caller owns via arena |
| `readFileAlloc` | `fn` (private) | Read full file content into allocator | `io`, `dir`, `path`, `allocator` | `![]u8` | Caller owns via arena |
| `sha256Hex` | `fn` (private) | SHA-256 hex string of data | `allocator`, `data` | `![]u8` (64 hex chars) | Caller owns via arena |
| `FileRec` | `struct` | File inventory record | `path`, `bytes`, `sha256` | — | Arena-owned |
| `Signal` | `struct` | PHP/CSS scan finding | `sourcepath`, `line`, `category`, `name`, `evidence`, `proposed`, `decision`, `unsupported` | — | Arena-owned |
| `walkTree` | `fn` (private) | Recursive directory walk, appending `FileRec` | `io`, `allocator`, `root`, `rel`, `files` | `!void`; mutates `files` | Paths arena-owned |
| `isIdent` | `fn` (private) | Test if byte is identifier char | `c` | `bool` | Pure |
| `hasCall` | `fn` (private) | Test if line contains a function call | `line`, `name` | `bool` | Pure; boundary-checks identifier chars |
| `firstQuoted` | `fn` (private) | Extract first quoted string from line | `allocator`, `line` | `!?[]const u8` | Caller owns via arena |
| `valueAfterKey` | `fn` (private) | Extract quoted value after a key in a line | `allocator`, `line`, `key` | `!?[]const u8` | Caller owns via arena |
| `mapKeys` | `fn` (private) | Extract all quoted string keys from a line | `allocator`, `line` | `![]const u8` | Caller owns via arena |
| `addSignal` | `fn` (private) | Append a `Signal` to the signal list | `allocator`, `signals`, fields | `!void` | Arena-owned |
| `callrules` | `const [...]CallRule` | Static table of PHP call patterns and their decisions | — | Used by `scanPhp` | Static; no allocation |
| `scanPhp` | `fn` (private) | Line-scan a PHP file for signals | `allocator`, `path`, `data`, `signals` | `!void`; mutates `signals` | Arena paths/evidence |
| `scanStyle` | `fn` (private) | Scan `style.css` for provenance fields | `allocator`, `path`, `data`, `signals` | `!void`; mutates `signals` | Arena paths/evidence |
| `signalLess` | `fn` (private) | Comparator for `Signal` sort | two `Signal` | `bool` | Pure |
| `fileLess` | `fn` (private) | Comparator for `FileRec` sort | two `FileRec` | `bool` | Pure |
| `ensureParent` | `fn` (private) | Create parent directory of output path | `io`, `root`, `rel` | `!void` | Side effect |
| `writeBytes` | `fn` (private) | Write bytes to output file (creates parent) | `io`, `root`, `rel`, `data` | `!void` | Side effect |
| `appendJson` | `fn` (private) | Append JSON-escaped string to buffer | `buf`, `allocator`, `s` | `!void` | Mutates buffer |
| `appendUsize` | `fn` (private) | Append decimal usize to buffer | `buf`, `allocator`, `n` | `!void` | Mutates buffer |
| `appendBool` | `fn` (private) | Append JSON bool to buffer | `buf`, `allocator`, `v` | `!void` | Mutates buffer |
| `countSignals` | `fn` (private) | Count signals matching a category | `signals`, `category` | `usize` | Pure |
| `emitInventory` | `fn` (private) | Serialize `inventory.json` | `allocator`, `root`, `files`, `signals` | `![]u8` | Caller owns |
| `emitManualReview` | `fn` (private) | Serialize `manualreview.json` | `allocator`, `signals` | `![]u8` | Caller owns |
| `emitSlots` | `fn` (private) | Return hardcoded `slotmapping.json` | `allocator` | `![]u8` | Caller owns |
| `emitPrototype` | `fn` (private) | Return hardcoded `prototypemain.html` | `allocator` | `![]u8` | Caller owns |
| `emitReport` | `fn` (private) | Serialize `report.json` | `allocator`, `root`, `files`, `signals` | `![]u8` | Caller owns |
| `emitReportMd` | `fn` (private) | Serialize `REPORT.md` | `allocator`, `files`, `signals` | `![]u8` | Caller owns |
| `refuseOutputInsideSource` | `pub fn` | Guard: output must not be inside source | `source`, `out` | `!void` (or `error.OutputInsideSource`) | Pure |
| `run` | `pub fn` | Main entry point for wordpress-theme mode | `io`, `gpa`, `opts: Options` | `!void` | Owns arena; cleans up on exit |

**`run` function walkthrough:**

1. Calls `refuseOutputInsideSource(opts.rootdir, opts.outdir)` — returns `error.OutputInsideSource` if violated.
2. Initializes `ArenaAllocator` backed by `gpa`; `defer arena.deinit()` ensures cleanup.
3. Opens `opts.rootdir` as `root: Io.Dir` — returns `error.SourceNotFound` on failure.
4. Calls `walkTree` recursively, collecting `FileRec` into `files` ArrayList.
5. Sorts `files.items` with `fileLess`.
6. Iterates `files.items`, line-scanning text files: PHP via `scanPhp`, `style.css` via `scanStyle`; unreadable files silently skipped.
7. Sorts `signals.items` with `signalLess`.
8. Creates `opts.outdir` with `createDirPath` — returns `error.IoFailure` on failure.
9. Opens `opts.outdir` as `out: Io.Dir`.
10. Writes all six output files via `writeBytes` using the emit functions.
11. If `!opts.quiet`, prints progress line to stderr.
12. Returns; `defer arena.deinit()` and `defer root.closeio` and `defer out.closeio` execute in reverse order.

## Ownership and lifetime model

- **`gpa` (GeneralPurposeAllocator):** Provided by `main.zig`'s `std.process.Init`; owns the arena.
- **`ArenaAllocator`:** Created at `run` entry, backed by `gpa`. All allocations for paths, file content, signal fields, and output buffers go through `arena.allocator()`. Freed by `defer arena.deinit()` on exit (both success and error).
- **Argument slices (`opts`):** Borrowed from `main.zig`'s argument ArrayList; lifetimes span the call to `run`.
- **`FileRec.path` and `FileRec.sha256`:** Arena-allocated strings from `joinRel` and `sha256Hex`.
- **File content (`data`):** Arena-allocated by `readFileAlloc`; used transiently within the scan loop.
- **Signal fields (`evidence`, `name` when constructed):** Arena-allocated by `addSignal` via `a.dupe`.
- **Output buffers (from emit functions):** Arena-allocated `ArrayList(u8)` → `toOwnedSlice`; owned by arena.
- **`Io.Dir` handles (`root`, `out`):** Closed by `defer` on success and error paths.
- **Cleanup on error:** Arena is deinitialized by `defer`; all file handles closed by `defer`. No explicit cleanup of partial `--out` content on failure.
- **Leak freedom:** Not demonstrated by allocator check tests. The arena model means no individual free is required, but arena memory is only reclaimed on `deinit`. No `std.testing.allocator` leak detection is applied to `run` in the inline tests (the determinism test uses `std.testing.allocator` but only for reading output, not for the `run` call which uses its own arena).

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--out` is inside `--root` | `refuseOutputInsideSource` in `run` | `main` logs `"migration-lab wordpress-theme failed: {s}"` | Exit 3 | No output written |
| `--root` does not exist / unreadable | `Io.Dir.cwd.openDir(rootdir)` | `main` logs error name | Exit 3 | No output written |
| Unreadable source file | `readFileAlloc` in scan loop | Silently skipped | Continues | File inventoried without signals |
| Output directory creation failure | `createDirPath(outdir)` | `main` logs error name | Exit 3 | No output written |
| `writeBytes` failure (any file) | Per-`writeBytes` call in `run` | `main` logs error name | Exit 3 | Partial output in `--out` |
| SHA-256 allocation failure | `sha256Hex` → `OutOfMemory` | `main` logs error name | Exit 3 | Partial output possible |
| Unknown CLI flag | `parseOptions` | `"unknown argument — try --help"` to stderr | Exit 2 | No output |
| Missing flag value | `parseOptions` | `"missing value for flag — try --help"` | Exit 2 | No output |
| Invalid mode value | `parseOptions` | `"invalid flag value — try --help"` | Exit 2 | No output |
| `--root` equals `--out` | `main.zig` guard | `"--out must differ from --root …"` | Exit 2 | No output |

Diagnostic mechanism: `std.log.err` (structured) for errors from `run`; `std.debug.print` for usage text and progress. No structured diagnostic type distinct from Zig error values is used.

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Imports this module; dispatches `wordpresstheme.run` | `main.zig` → `wordpresstheme.zig` | `main.zig` owns dispatch and CLI parsing |
| `tools/migration-lab/build.zig` | Compiles this file as part of `boris-migration-lab` | Build system → source | `build.zig` is the build authority |
| `tools/migration-lab/fixtures/mini-wordpress-kubrick/` | Test fixture (synthetic) | This module reads fixture | Fixture is input evidence; not authentic Kubrick |
| `tools/migration-lab/README.md` | Documents `wordpress-theme` mode, flags, outputs, safety rules | Documentation | README is documentation; source is authoritative for behavior |
| `tools/migration-lab/themearchaeology.zig` | Sibling module; `refuseOutputInsideSource` also exported by `wordpresstheme.zig`; `themematerialize.zig` calls `archaeology.refuseOutputInsideSource`, not this module's version | Parallel | Independent; no import relationship |
| Boris product `src/` | No relationship | — | Not imported |
| Root `build.zig` | No relationship | — | Deliberately excluded |

## Security and trust boundaries

**Untrusted repository paths:** File paths from the source tree walk are used as JSON string values in output. `appendJson` escapes control characters and quotes. However, no validation rejects paths containing embedded null bytes, `..` segments, or other hostile values from appearing in the JSON string content. These are written as opaque strings, not executed.

**Arbitrary source-file bytes:** PHP and CSS file content is read and line-scanned. Individual lines are included verbatim as `evidence` fields in `Signal` records and written to JSON via `appendJson`. The escaping covers JSON safety but does not sanitize for downstream execution. If output JSON is later parsed and the `evidence` string is rendered in a terminal or browser without additional escaping, hostile content (ANSI escape sequences, HTML, etc.) could be displayed.

**PHP fence safety:** PHP is never executed. Line content is included as evidence strings. There is no Markdown fence wrapping of PHP content in `REPORT.md`; PHP lines appear directly in the signal list as plain text. Downstream Markdown rendering of `REPORT.md` would not execute them, but hostile PHP lines are not neutralized before inclusion.

**Generated bundle delimiters:** Not applicable to this module.

**Path traversal (output side):** `ensureParent` and `writeBytes` use fixed relative paths (`inventory.json`, `slotmapping.json`, etc.) — not derived from source filenames. No output file path is constructed from user-controlled source paths.

**Symlink traversal:** Not handled; `Dir.iterate()` on symlinks is platform-dependent. A hostile symlink in the theme source tree could cause the walk to follow out of `rootdir`.

**Output overwrite:** Unconditional; prior valid output is overwritten. A failed partial run leaves mixed-state output.

**Resource exhaustion:** No file size limit in `readFileAlloc` (uses `.unlimited`). A very large PHP file in the source tree could cause OOM.

**Maliciously chosen filenames:** Filenames are used as JSON strings (escaped by `appendJson`) and as scan-root-relative paths in output. No validation rejects hostile filename bytes.

**Network exfiltration:** Absent. No socket API used.

**Trusted vs. untrusted:**

- `opts.rootdir`, `opts.outdir`: trusted only to the extent of caller-provided CLI arguments; `refuseOutputInsideSource` limits output containment.
- File content from `--root`: treated as opaque bytes for hashing and as text for line scanning; never executed.
- `callrules` table: static, trusted.
- Output paths for the six files: hardcoded strings, trusted.

## Evidence limitations

- The `fixtures/mini-wordpress-kubrick` fixture is synthetic and explicitly not authentic Kubrick code. Coverage of real-world WordPress theme patterns beyond the modeled set is uncertain.
- `build.zig` content was not directly inspected; build wiring is inferred from `main.zig` imports, README documentation, and the source-RAG catalog, which confirm standalone build and executable name.
- Cross-platform byte identity of output is not tested. Path separator behavior (`joinRel` uses `/`) may differ on Windows.
- Symlink behavior during `walkTree` is not tested and is uncertain.
- Allocation failure paths (`OutOfMemory` from arena) are not tested.
- I/O failure paths (partial write, `writeBytes` failure mid-run) are not directly tested.
- The `themematerialize.zig` test that covers `refuseOutputInsideSource` calls the version from `archaeology.zig`, not `wordpresstheme.zig`; it is not directly confirmed that both implementations are identical, though the source text shows the same logic.
- `tools/source-rag/` evidence was not available; the file was assessed purely from `tools/migration-lab/` source.
- No `CHANGELOG.md` specific to `wordpresstheme.zig` was visible in the source bundle.
- `tools/migration-lab/build.zig` is listed in the catalog (1238 bytes) but its full content was not retrieved; build step names and optimization flags are uncertain beyond what the README documents.

## Final source assessment

`tools/migration-lab/theme_wordpress_theme.zig` is a self-contained, moderately-sized implementation module responsible for all data structures, scanning logic, serialization, and inline tests for the `wordpress-theme` mode of the Boris migration laboratory. It is fully isolated from the Boris product runtime — no product source is imported, and it is not compiled into the `boris` binary.

**Strongest supported guarantees:** Output-directory containment (`refuseOutputInsideSource`, called at `run` entry); byte-identical repeated runs against the same fixture (directly demonstrated); no PHP execution (structurally absent); no network access (structurally absent); source tree immutability (no write path to source).

**Weakest or least-tested boundaries:** Symlink traversal during `walkTree` (not handled, not tested); behavior on very large files (no size cap); partial output on mid-run failure (no atomic replacement); cross-platform path and byte identity (not tested); hostile filename bytes in JSON output (escaping applied but not adversarially tested).

**Separation from Boris product runtime:** Complete. No shared modules, no shared build, no runtime coupling.

**Quality of available evidence:** Good for the happy path (determinism, classifier, signal presence). Thin for failure paths, hostile inputs, and cross-platform behavior.

**Most important unresolved question:** Whether `walkTree` follows symlinks out of `--root` on supported platforms, and whether this constitutes an exploitable path for a hostile theme archive to read files outside the intended scan root.
