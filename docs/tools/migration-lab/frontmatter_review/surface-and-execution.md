---
title: "`tools/migration-lab/frontmatter_review.zig` surface and execution"
id: docs/tools/migration-lab/frontmatter_review/surface-and-execution
parent: docs/tools/migration-lab/frontmatter_review
status: draft
tags: [boris, zig, tools, surface, migration-lab, frontmatter_review]
---

# `tools/migration-lab/frontmatter_review.zig` surface and execution

## CLI surface

CLI parsing lives entirely in `tools/migration-lab/main.zig` (`parseOptions`). The `frontmatterreview.zig` module only receives a `RunOptions` struct. The relevant CLI surface from `main.zig`:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode frontmatter-review` | No (implied by `--content`) | `astro` | `frontmatter-review`, `fm-review`, `fmreview` | Selects frontmatter-review mode | `error.InvalidValue` → exit 2 |
| `--content DIR` | Yes for this mode | none | Any readable directory path | Sets content tree root; implies mode | `error.MissingValue` → exit 2 |
| `--out DIR` | No | `migration-report` | Any writable path | Sets output directory (created if missing) | `error.MissingValue` → exit 2 |
| `-q` / `--quiet` | No | false | flag | Suppresses progress line to stderr | — |
| `-h` / `--help` | No | false | flag | Prints usage and exits 0 | — |

**Additional constraints enforced in `main.zig` for this mode:**

- `--out` must differ from `--content`; violation → stderr message + exit 2.
- `--content` with no value → `error.MissingValue` → exit 2.
- Unknown flags → `error.UnknownFlag` → exit 2.

**Exit codes:**

- 0: success (including `--help`).
- 2: usage error (CLI parse failure, missing required flag, `--out == --content`).
- 3: I/O error from `frontmatterreview.run` (propagated as `ExitCode.ioerror`).

Exact exit-code semantics are structurally enforced by the `ExitCode` enum in `main.zig` (`success = 0`, `usage = 2`, `ioerror = 3`), which is directly demonstrated by CLI tests.

***

## Inputs and discovery model

The tool treats the path supplied to `--content` as the scan root. Discovery is performed by `collectFiles`, a recursive directory walker.

**Discovery rules:**

- All `.md` and `.mdx` files anywhere under the root are candidates (tested by `isMarkdown`).
- Directories named `.git`, `.hg`, `node_modules`, `dist`, `zig-out`, `zig-cache`, `.zig-cache`, `.boris`, `.output`, `.vercel`, `.netlify` are skipped.
- Any directory whose name starts with `.` (i.e., any hidden directory not already in the explicit list) is also skipped via the `shouldSkip` fallback: `if (name.len > 0 and name[^1_0] == '.') return true`.
- Files are identified by name only (no content sniffing). The basename must end with `.md` or `.mdx`.
- After collection, the file list is sorted lexicographically on relative path before scanning.

**No distinction is made between:**

- Files with frontmatter and files without (files without frontmatter are scanned and then silently dropped from results).
- Files tracked by git and ignored files (no `.gitignore` awareness).
- Symlinks (no symlink detection; symlinks are followed by `openFile` on most platforms).

**Frontmatter parsing:**

- Only files beginning with `---` or `---\r\n` are considered to have frontmatter.
- The closing `---` must appear at column 0 and be followed by EOF, `\n`, or `\r\n`. A fence with trailing content on the closing line is treated as unclosed.
- Indented lines and lines starting with `-` (YAML list items) are skipped inside the frontmatter block — tested explicitly for `tags` list items.
- No YAML evaluation is performed; values are captured as trimmed raw bytes.

| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| `.md` files | Recursive walk, `isMarkdown` check | Yes | Skip-dir list; hidden dirs | Inline tests; `collectFiles` source |
| `.mdx` files | Same | Yes | Same | `isMarkdown` checks both extensions |
| Files without frontmatter | Collected, then silently excluded from report | Collected | Excluded from `reviews` list | `run` body: `if (scanned.occurrences.len == 0 and !scanned.incompatibleFence) continue` |
| Files with only Boris keys | Collected, scanned, excluded from report | Excluded | Same condition | `scanFile` test: Boris keys not flagged |
| Files in skip dirs | Not collected | No | `.git`, `zig-out`, hidden dirs | `shouldSkip` in `collectFiles` |


***

## Output artifact model

The tool produces exactly two output files, both written directly to the `--out` directory.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `frontmatterreview.json` | Hand-serialized JSON, schema version 1, format id `boris-frontmatter-review-lab` | Tool-generated, disposable | Files sorted by path; keys in source order | Machine consumers, LLM review workflows | Format id and schema version present; no separate versioning test |
| `FRONTMATTERREVIEW.md` | Markdown with per-file H3 sections and a table per file | Tool-generated, disposable | Same sort order | Human migration author | No stability test; format is not versioned |

**No other artifacts are produced.** There is no index, catalog, manifest, bundle, or staging file. There is no cleanup of stale outputs from previous runs.

**Output replacement behavior:**

- Both files are written unconditionally on each run via `out.writeFile`. If a previous run produced files in `--out`, they are overwritten.
- Files from a prior run that are no longer generated (e.g., if the second run targets a different content root) are not deleted. This is a residual gap: stale outputs from a prior content root can coexist with new outputs.

**Required for a minimally useful result:** both files are always produced together; neither is optional.

***

## Serialization and schema behavior

The JSON serializer is hand-rolled (`appendJson`, `appendUsize`). It does not use `std.json`. Field ordering is deterministic and follows declaration order in the source.

**Top-level JSON structure (`frontmatterreview.json`):**

```json
{
  "format": "boris-frontmatter-review-lab",
  "schemaVersion": 1,
  "toolVersion": "0.1.0",
  "sourceRoot": "<--content value>",
  "totalUnknownKeys": <usize>,
  "totalOccurrences": <usize>,
  "files": [
    {
      "sourcePath": "<repo-relative path>",
      "incompatibleFence": <bool>,
      "unknownKeys": [
        ```
        { "key": "<key>", "line": <1-based line in frontmatter block>, "value": "<raw value>" },
        ```
        ...
      ]
    },
    ...
  ]
}
```

Line numbers are 1-based within the file; the opening `---` is line 1, so the first field is line 2 minimum. Values are trimmed of whitespace; no YAML unquoting is performed.

**Markdown output (`FRONTMATTERREVIEW.md`):**

- Contains a summary header with source root, tool version, total occurrences, and total files with unknown keys.
- Per-file H3 section with `sourcePath` as heading.
- If `incompatibleFence` is true, a note is prepended: "Unclosed frontmatter fence — keys below may be incomplete."
- A three-column table `| Line | Key | Raw value |` for each occurrence.
- Pipe characters in key or value are escaped as `&#124;` (demonstrated by test `test escapeMdCell pipe is escaped`).
- Newlines in values become spaces.
- When no files have unknown keys, a single "None — all files use only supported Boris frontmatter keys." line is emitted (demonstrated by `test emitMd no-unknown case says None`).

| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `frontmatterreview.json` | `"format":"boris-frontmatter-review-lab"`, `"schemaVersion":1` | `emitJson` | Files by path; keys by source occurrence order | Inline tests check field presence and key ordering; no golden byte test |
| `FRONTMATTERREVIEW.md` | No version identifier | `emitMd` | Same as JSON | Inline tests check section headers and table presence |


***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable file discovery order | `collectFiles` accumulates paths then `std.mem.sort` with lexicographic comparator | Structurally checked | Relies on consistent byte representation of paths across platforms |
| Stable key occurrence order within file | Keys appended in line-scan order; no reordering | Structurally checked | Source order; not explicitly tested as invariant |
| No timestamps in output | Serializer writes only static strings, path, counts, and key/value bytes | Structurally checked | — |
| No random identifiers | No random or UUID generation anywhere in file | Structurally checked | — |
| No absolute paths in JSON | `sourceRoot` is the caller-supplied `opts.sourceRoot` (may be absolute if caller passes absolute path) | Depends on caller discipline | Caller-relative paths will vary across machines if absolute |
| Repeated-run byte identity | Fixture test `fm-review-no-unknown` runs `run` and checks JSON/MD content | Partial coverage | No explicit two-run byte-for-byte comparison test |
| Platform path separator | `collectFiles` uses `/` separator via `std.fmt.allocPrint("{s}/{s}")` | Structurally checked | Not tested on Windows |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Writing into source tree | `run` checks `opts.outDir` equals or is prefixed by `opts.sourceRoot` | Yes — returns `error.OutputInsideSource` | Not directly tested by a dedicated path-safety test | String prefix check; symlinks not resolved |
| Output overwrites valid prior output on failure | No staging; writes are direct | No | No | A partial run failure leaves partial output |
| Stale outputs from prior run persist | No cleanup logic | No | No | Files from a prior run with a different `--content` root coexist |
| Symlink traversal into output from content tree | `shouldSkip` skips hidden dirs only; no symlink detection | No | No | A symlink in the content tree pointing outside is followed |
| `..` in discovered paths | `collectFiles` constructs paths as `"{prefix}/{entry.name}"` where `entry.name` is from `Dir.iterate` (OS-provided basename, no `..`) | Structurally checked by OS iterator semantics | No explicit test | — |
| Very large files | `allocRemaining(.unlimited)` — entire file read into arena memory | No size limit | No | Adversarially large files could exhaust process memory |
| Malicious filenames (pipe, newline in filename → Markdown output) | `escapeMdCell` escapes `|` and replaces newlines with spaces | Yes for values; filenames used as section headings (H3) — not escaped through `escapeMdCell` | Partial (value escaping tested) | File paths used as Markdown H3 headings are not escaped |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `formatId` | `pub const []const u8` | JSON format identifier string | — | `"boris-frontmatter-review-lab"` | static |
| `schemaVersion` | `pub const u32` | JSON schema version | — | `1` | static |
| `toolVersion` | `pub const []const u8` | Tool version string | — | `"0.1.0"` | static |
| `borisKeys` | `const []const []const u8` | Closed Boris grammar key list | — | 5 strings | static |
| `isBorisKey` | `fn` | Test whether a key is in the closed grammar | `key: []const u8` | `bool` | — |
| `trim` | `fn` | Whitespace trim | `s: []const u8` | trimmed slice | borrows |
| `escapeMdCell` | `fn` | Escape `|` and newlines for Markdown table cell | `a`, `s` | allocated `[]u8` | caller owns |
| `KeyOccurrence` | `pub const struct` | One unknown-key occurrence within a file | key, line, value | data | arena-owned |
| `FileReview` | `pub const struct` | Per-file review record | sourcePath, unknownKeys, incompatibleFence | data | arena-owned |
| `ScanResult` | `pub const struct` | Full scan result | sourceRoot, files, totals | data | arena-owned |
| `scanFile` | `pub fn` | Parse one file's frontmatter and collect unknown keys | `a`, `source: []const u8` | `{occurrences, incompatibleFence}` | caller arena |
| `shouldSkip` | `fn` | Directory skip predicate | `name: []const u8` | `bool` | — |
| `isMarkdown` | `fn` | File inclusion predicate | `name: []const u8` | `bool` | — |
| `WalkEntry` | `const struct` | Discovered file entry | relpath | data | arena |
| `collectFiles` | `fn` | Recursive directory walk | `io`, `a`, `root`, `relPrefix`, `out` | appends to `out` | arena |
| `appendJson` | `fn` | JSON-escape and append a string | `buf`, `a`, `s` | appends to `buf` | buf-owned |
| `appendUsize` | `fn` | Append decimal usize | `buf`, `a`, `value` | appends to `buf` | buf-owned |
| `emitJson` | `pub fn` | Serialize `ScanResult` to JSON bytes | `a`, `result` | allocated `[]u8` | caller owns |
| `emitMd` | `pub fn` | Serialize `ScanResult` to Markdown bytes | `a`, `result` | allocated `[]u8` | caller owns |
| `RunOptions` | `pub const struct` | Options for `run` | sourceRoot, outDir, quiet | — | — |
| `run` | `pub fn` | Full execution: discover, scan, emit, write | `io`, `gpa`, `opts` | writes two files to `opts.outDir` | arena owns all temporaries; freed on return |

**`run` function detail:**

1. Guard: `error.OutputInsideSource` if `outDir` == `sourceRoot` or is a prefix of it.
2. Arena allocator initialized from `gpa`; freed via `defer arena.deinit()`.
3. Open `sourceRoot` as `Io.Dir`.
4. Call `collectFiles` to accumulate `WalkEntry` list.
5. Sort entries lexicographically on `relpath`.
6. For each entry: open file, `allocRemaining` into arena, call `scanFile`. Skip files with zero occurrences and no fence issue.
7. Accumulate `allKeyNames` list (deduplicated by name) and `reviews` list.
8. Construct `ScanResult`.
9. `Io.Dir.cwd.createDirPath(opts.outDir)`.
10. Open `opts.outDir`.
11. Call `emitJson`, write `frontmatterreview.json`.
12. Call `emitMd`, write `FRONTMATTERREVIEW.md`.
13. If not quiet, print summary to stderr.

***

## Ownership and lifetime model

- **GPA (`gpa`)**: process allocator passed in from `main`; used only to initialize the arena.
- **Arena (`arena`)**: initialized from `gpa` in `run`; holds all discovered paths, file bytes, `KeyOccurrence` slices, `FileReview` slices, serialized output bytes. Freed via `defer arena.deinit()` at `run` return, whether success or error.
- **File handles**: `sourcedir` and `out` are opened and closed with `defer dir.close(io)`.
- **Per-file file handle**: opened and closed inside the scan loop with `defer file.close(io)`.
- **`raw` bytes (file contents)**: allocated into arena via `allocRemaining`; freed at arena deinit.
- **`KeyOccurrence` slices**: keys and values duplicated into arena; owned by arena.
- **`emitJson`/`emitMd` output buffers**: allocated into arena via `buf.toOwnedSlice(a)`; written to disk, then freed at arena deinit.
- **`allKeyNames`**: `ArrayListconst u8` accumulating arena-owned slices; not freed individually.

Inline tests use `std.testing.allocator` (a leak-detecting allocator) and arena patterns. Tests that allocate but do not defer free would be caught. The `scanFile` tests use `arena.allocator()` with `defer arena.deinit()`; the `emitJson` and `emitMd` tests allocate results but defer the allocator's deallocation. No explicit leak-freedom assertion (e.g., `testing.checkAllocLeak`) is present.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--out` == `--content` (string) | `main.zig` before calling `run` | Stderr: "--out must differ from --content" | Exit 2 | No output written |
| `--content` not supplied in frontmatter-review mode | `main.zig` | Stderr: "frontmatter-review mode requires --content DIR" + usage | Exit 2 | No output written |
| Unknown CLI flag | `parseOptions` | Stderr: "unknown argument — try --help" | Exit 2 | No output written |
| Missing CLI flag value | `parseOptions` | Stderr: "missing value for flag" | Exit 2 | No output written |
| `OutputInsideSource` (prefix check) | `run` guard | Propagated as `error.OutputInsideSource` → `main` logs `"migration-lab frontmatter-review failed: OutputInsideSource"` | Exit 3 | No output written |
| `sourceRoot` not openable | `Io.Dir.cwd.openDir` | Same error propagation → exit 3 | Exit 3 | No output written |
| Unreadable file inside content tree | `sourcedir.openFile` | Same propagation | Exit 3 | Prior files may have been scanned; no partial JSON written (output written after full scan) |
| `outDir` creation failure | `createDirPath` | Same propagation | Exit 3 | No output written |
| Write failure (`writeFile`) | `out.writeFile` | Same propagation | Exit 3 | First file may be written; second not |
| Allocation failure | Arena `allocRemaining` or `ArrayListappend` | Propagated as OOM error | Exit 3 | Depends on point of failure |
| Unclosed frontmatter fence | `scanFile` | Not an error; `incompatibleFence: true` in output | Normal exit 0 | — |

All diagnostic messages to the user are plain stderr strings via `std.log.err` in `main.zig` or `std.debug.print` for the summary line. No structured diagnostic format is produced beyond the JSON output.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Importer; dispatches to `frontmatterreview.run` | `main.zig` → `frontmatterreview.zig` | `main.zig` owns CLI parsing and mode dispatch |
| `tools/migration-lab/build.zig` | Build integration; compiles this file as part of `boris-migration-lab` | `build.zig` → `main.zig` → `frontmatterreview.zig` | `build.zig` defines the executable |
| `tools/migration-lab/fixtures/fm-review-no-unknown/` | Test fixture; read-only content tree with only Boris keys | `run` reads | Fixture is test input evidence |
| `tools/migration-lab/fixtures/fm-review-mixed/` | Test fixture; content tree with mixed Boris and unknown keys | `run` reads | Fixture is test input evidence |
| `src/frontmatter.zig` (Boris product) | **Not imported**; module comment explicitly states this | None | No relationship |
| `docs/contracts/frontmatter.md` | Boris closed author grammar reference | Informational (not imported) | Normative for the Boris product; mirrored as local constant here |
| `tools/migration-lab/obsidian.zig`, `wordpress.zig`, etc. | Sibling mode modules in the same binary | Parallel | No direct relationship |


***

## Security and trust boundaries

**Untrusted input:** The content tree is treated as untrusted. File bytes are read verbatim into arena memory. Key and value bytes from frontmatter are captured and written into JSON and Markdown without any interpretation of their content.

**JSON safety:** The hand-rolled `appendJson` serializer escapes `"`, `\`, `\n`, `\r`, `\t`, and `\0`. Control characters outside the listed set are emitted verbatim. This is not a fully compliant JSON escaper for arbitrary byte sequences; bytes in the range U+0001–U+001F outside the five listed escapes are not escaped.

**Markdown table safety:** `escapeMdCell` escapes `|` and converts newlines to spaces. This prevents pipe-injected table breakage for key and value strings. However, file paths used as Markdown H3 headings (`### {sourcePath}`) are not passed through `escapeMdCell`. A path containing `|`, `#`, or Markdown special characters could produce malformed Markdown output.

**Path traversal:** The content tree walk constructs relative paths by appending `/{entry.name}` where `entry.name` is provided by the OS directory iterator (never contains `/` or `..`). The output directory containment check uses string prefix matching on the caller-supplied paths without symlink resolution.

**Symlinks:** No symlink detection. Symlinks in the content tree are followed by `openFile`; symlinks to directories are followed by `openDir`. A symlink pointing outside the content tree (e.g., to a system file or the output directory) would be followed silently.

**Resource exhaustion:** Files are read with `.unlimited` allocation. No cap on file size, file count, or total memory.

**Network exfiltration:** Not possible; no network calls are made anywhere in the file.

**Terminal output:** The stderr summary line contains the caller-supplied `opts.outDir` string. No key or value content is echoed to stderr.

***

## Evidence limitations

- The source pack contains `frontmatterreview.zig` in full (30,040 bytes). All claims about its implementation are directly supported by that source.
- The `tools/migration-lab/build.zig` was read in full (1,238 bytes) and confirms the standalone build model.
- `tools/migration-lab/main.zig` was read in full and confirms the CLI surface, mode dispatch, and test declarations.
- The fixture directories `fixtures/fm-review-no-unknown` and `fixtures/fm-review-mixed` were referenced in test code but their contents were not directly inspected. Coverage claims for fixture tests depend on the test passing, not on the fixture contents being verified here.
- `AGENTS.md`, `docs/STATUS.md`, root `build.zig`, and root `build.zig.zon` were not inspected. Whether the root build exposes the migration lab as a convenience step is uncertain.
- No CI configuration was inspected; cross-platform test evidence is unavailable.
- `toolVersion` is `"0.1.0"` per source; no changelog for `frontmatterreview.zig` specifically was found. Version history and schema evolution history are unavailable.
- The claim that `frontmatterreview.json` schema is stable is uncertain; no versioning test exists and the schema has not been subjected to a compatibility check.
- Behavior of the JSON serializer for non-UTF-8 byte sequences in key or value fields is not tested and not specified.

***

## Final source assessment

`tools/migration-lab/frontmatter_review.zig` is a focused, self-contained analysis module with a single well-defined responsibility: reporting unknown frontmatter keys in a content tree. Its separation from the Boris product runtime is structurally enforced — it imports no product modules and the build system does not link it into the product binary. The `run` function is the only entry point consumed externally; all other declarations are implementation details.

The strongest guarantees are: no source file is ever modified; output is never written into the source tree (enforced by the `OutputInsideSource` guard); all key occurrences are captured with source-accurate line numbers; the Boris closed grammar is consistently applied; and output is sorted deterministically. These properties are directly demonstrated by inline and fixture tests.

The weakest or least-tested boundaries are: stale-output cleanup (not implemented); Markdown output safety for paths with special characters; JSON escaping completeness for non-UTF-8 or control-character input; and absence of a byte-for-byte repeated-run test. The file does not prove its own cross-platform behavior.

The most important unresolved question is whether the absence of stale-output cleanup is intentional policy for this mode or an oversight relative to sibling migration-lab modes that do wipe their output trees on re-run.
