---
title: "`tools/migration-lab/filed.zig` surface and execution"
id: docs/tools/migration-lab/filed/surface-and-execution
parent: docs/tools/migration-lab/filed
status: draft
tags: [boris, zig, tools, surface, migration-lab, filed]
---

# `tools/migration-lab/filed.zig` surface and execution

## CLI surface

CLI parsing is entirely in `main.zig`. `filed.zig` has no CLI parsing logic; it receives a pre-parsed `RunOptions` struct. The flags relevant to filed mode are parsed by `parseOptions` in `main.zig` and dispatched in the `.filed` branch.


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode filed` | No (implied) | `astro` | `filed`, `filed-fyi` | Selects filed migration mode | `error.InvalidValue` → exit 2 |
| `--filed-root &lt;DIR>` | Yes (for filed mode) | none | Any non-empty path | Sets `sourcerootdir`; implies `--mode filed` | Missing → exit 2 with usage |
| `--out &lt;DIR>` | No | `migration-report` | Any non-empty path | Sets output directory | Missing value → exit 2 |
| `-q`, `--quiet` | No | off | flag | Suppresses progress output | N/A |
| `-h`, `--help` | No | off | flag | Prints usage, exits 0 | N/A |

**Output-equals-source guard:** `main.zig` checks `opts.filed_root_dir == opts.outdir` and exits 2 with an error message before calling `filed.run`. The guard in `filed.run` itself additionally checks whether `outdir` is a path-prefix child of `sourcerootdir` (`error.OutputInsideSource`); this covers e.g. `--out <source>/out`.

**Cardinality failure:** `error.UnexpectedCollectionCardinality` propagates from `run` to `main`, which logs it and exits 3.

**Exit codes:** 0 (success), 2 (usage error), 3 (IO/runtime error). Exact exit codes are declared in `main.zig` as `ExitCode.success`, `ExitCode.usage`, `ExitCode.io_error`.

***

## Inputs and discovery model

`filed.zig` uses a fixed, non-recursive discovery pattern. `collectCollection` opens `src/content/docs/<collection_name>/` under the source root and iterates immediate directory entries. Only entries with `entry.kind == .file` whose names end in `.md` or `.mdx` are processed. No subdirectory recursion occurs within a collection directory.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| `src/content/docs/changelog/` | `openDir` + `iterate`, immediate files only | All `.md`/`.mdx` files | Non-files; non-Markdown names | `collectCollection` in source |
| `src/content/docs/releases/` | Same | All `.md`/`.mdx` files | Same | Same |
| Other paths in source root | Not traversed | N/A | Everything else | No `walkTree` or recursive call |
| Symlinks | Not followed or rejected | — | Not explicitly handled; treated as non-file or opened opaquely | Uncertain — see path safety |
| MDX files | Included by `isMarkdown` check | Yes | None | `isMarkdown` returns true for `.mdx` |

The source root is opened with `openDir(io, opts.sourcerootdir, .{ .iterate = true })`. All subsequent opens are relative to this dir handle; no absolute-path construction from source paths occurs.

**Cardinality enforcement:** After both collections are collected, `run` checks `changelog_count == 1` and `records.items.len - changelog_count == 3`. If either condition fails, `error.UnexpectedCollectionCardinality` is returned before any output is written.

**Sorting:** Records are sorted by `sourcepath` using `std.mem.order(u8, x.sourcepath, y.sourcepath)` after both collections are appended. This produces lexicographic byte order.

***

## Output artifact model

| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/changelog/<slug>.md` | Boris-ready Markdown with YAML frontmatter | Tool-generated; disposable | Sorted by sourcepath | Human reviewer; Boris product compiler | Not versioned beyond schema 2 |
| `content/releases/<slug>.md` | Same | Same | Same | Same | Same |
| `content/changelog/index.md` | Markdown stub | Tool-generated | Fixed content | Human reviewer | Stable within schema 2 |
| `content/releases/index.md` | Markdown stub | Same | Fixed content | Same | Same |
| `provenancemanifest.json` | JSON array (one object per record) | Tool-generated | Records sorted by sourcepath | Audit workflows | Schema 2; no separate schema file |
| `report.json` | JSON object | Tool-generated | Fixed key order | Audit workflows | Schema 2; no separate schema file |

**Output directory creation:** `Io.Dir.cwd.createDirPath(io, opts.outdir)` is called before any file write. No staging or atomic rename is performed; output is written in place.

**Stale output:** No stale-output cleanup is performed. If the output directory already exists from a prior run, old files are overwritten where paths match, but files whose paths no longer appear in the current run are not deleted.

**Provenance manifest format:** The manifest is a JSON object with a `records` array. Each element contains `collection`, `sourcepath`, `outputpath`, `rawfrontmatter`, `unmappedfrontmatterfields`, and a nested `parentnormalization` object. The manifest is emitted as a single JSON value, not JSONL despite the source-RAG catalog calling it "JSONL-style" — inspect the source: it is a single JSON document with a `records` array.

**Report format:** The `report.json` contains `format`, `schemaversion`, `toolversion`, `sourceroot`, `convertedrecords` (count: 4), and a `parentnormalization` breakdown by status, plus an `unmappedfrontmatter` array if any unmapped keys were found.

***

## Serialization and schema behavior

All JSON serialization is performed by hand using `appendJson` (string with JSON escaping) and `appendUsize` helpers. There is no dependency on `std.json` for emission. Fields are emitted in a fixed, declaration-order sequence. The `appendJson` function escapes `"`, `\`, `\n`, `\r`, `\t`, and `\x00` by Unicode escape; other control characters below 0x20 are not explicitly handled (uncertain gap).

**Format identifiers:**

- Provenance manifest: `"format": "boris-filed-fyi-provenance"`, `"schemaversion": 2`
- Report: `"format": "boris-filed-fyi-migration-lab"`, `"schemaversion": 2`
- `tool_version`: `"0.1.1"` (string constant)

No schema file exists in the repository for these formats; the schema is implicit in the source. There is no version-disagreement handling; the tool always emits schema 2.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `provenancemanifest.json` | `boris-filed-fyi-provenance` / 2 | `run` in `filed.zig` | Records sorted by sourcepath | Inline fixture test (structure only) |
| `report.json` | `boris-filed-fyi-migration-lab` / 2 | `run` in `filed.zig` | Fixed key order | Inline fixture test (structure only) |
| Per-record `.md` output | No format identifier; Boris frontmatter subset | `emitPage` | N/A | Inline fixture test checks field presence |

**Newline policy:** Body text is written as-read; no newline normalisation is applied. JSON strings use `\n` escape for embedded newlines.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Records sorted by sourcepath | `std.mem.sort` on `sourcepath` field, lexicographic | Structurally checked | Filesystem enumeration order affects collection before sort; sort normalises across runs |
| Slug generation is pure function of filename | `slugAlloc` lowercases and replaces non-alnum with `-`; no timestamp or random input | Structurally checked | Filename encoding differences across platforms could produce different slugs (uncertain) |
| No timestamps in output | No `std.time` call anywhere in file | Structurally checked | None identified |
| No random identifiers | No PRNG call | Structurally checked | None identified |
| No absolute paths in output | `sourcepath` is relative to source root; `outputpath` is relative to output root | Structurally checked | Source root string itself is embedded in `report.json`; differs if `--filed-root` differs |
| Map iteration order | No `std.HashMap` used in output construction; all collections are `std.ArrayList` | Structurally checked | None |
| Byte-for-byte repeated-run identity | Not directly tested; no golden comparison test exists | Uncertain | Stale-output non-cleanup means re-runs may leave unreferenced old files |
| Cross-platform identity | Not tested | Uncertain | Path separator handling depends on `std.fs.path` conventions |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output directory equals source root | String equality check in `run`; also checked in `main.zig` | Yes (string comparison) | Uncertain | String comparison is not symlink-aware |
| Output directory is child of source root | Prefix check in `run` (`startsWith` + separator char) | Yes (string comparison) | Uncertain | Not symlink-aware |
| Path traversal via source filenames | `collectCollection` builds `rel` as `src/content/docs/<name>/` + `entry.name`; `entry.name` comes from `dir.iterate()`, not from file content | Structurally | Partial — no explicit traversal-rejection test for `filed` mode | Names like `../evil.md` would come from the real filesystem; not explicitly rejected |
| Traversal in parent values | `isSafeParentId` rejects values containing `/`, `..` segments, spaces, control chars | Yes | Tested inline (`isSafeParentId` unit tests) | Only the emitted parent value is checked; raw frontmatter is preserved as-is in manifest |
| Symlink traversal in source | `dir.iterate()` returns `entry.kind`; only `.file` is processed | Partial — symlinks with `kind != .file` skipped | Uncertain | `kind == .file` for a symlink-to-file on some platforms; not explicitly tested |
| Output overwrite | Existing files are overwritten silently | Not mitigated | Not tested | No atomic rename; partial write on failure leaves corrupt output |
| Stale output files | Not cleaned up | Not mitigated | Not tested | Re-run with fewer records leaves orphaned files |
| Recursion into own output | Output dir is not within source root (enforced by prefix check) | Yes | Uncertain | Only if containment check passes |
| Very large files | `allocRemaining` with `.unlimited` | Not bounded | Not tested | Allocation failure propagates as `OutOfMemory` |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const` string | Machine format identifier for provenance manifest | — | `"boris-filed-fyi-migration-lab"` | Static |
| `schema_version` | `pub const u32` | Schema version for emitted JSON | — | `2` | Static |
| `tool_version` | `pub const` string | Tool version string embedded in output | — | `"0.1.1"` | Static |
| `RunOptions` | `pub const struct` | Options passed by `main.zig` dispatcher | `sourcerootdir`, `outdir`, `quiet` | Consumed by `run` | Borrowed slices from CLI args; owned by caller |
| `Collection` | `pub const enum` | Identifies changelog vs. releases collection | — | `.changelog`, `.releases` | Static |
| `ParentNormStatus` | `pub const enum` | Outcome of parent-key normalisation | — | `.missing`, `.identity`, `.normalized`, `.conflict`, `.invalid` | Per-record |
| `ParentKeyOccurrence` | `pub const struct` | One occurrence of a parent-family key in frontmatter | key, value, line | Stored in `ParentNormalization.original_keys` | Arena-owned |
| `ParentNormalization` | `pub const struct` | Full result of `normalizeParentKeys` | — | Status, emitted parent, original keys, reason | Arena-owned |
| `isSafeParentId` | `pub fn` | Validates a candidate parent entity-id string | `id: []const u8` | `bool` | Pure function; no allocation |
| `normalizeParentKeys` | `pub fn` | Deterministic parent-key normalisation | allocator, frontmatter bytes, first-field line number | `!ParentNormalization` | Allocates key/value slices in caller allocator |
| `run` | `pub fn` | Main entry point for filed mode | `Io`, `gpa`, `RunOptions` | `!void`; writes output tree | Arena for all per-run allocations; deinits on return |
| `collectCollection` | `fn` (private) | Discovers and parses one collection directory | Io, allocator, source Dir, Collection, record list | Appends to `records` | Arena-owned record fields |
| `parseSource` | `fn` (private) | Parses frontmatter and body from raw Markdown bytes | allocator, raw bytes, fallback title | `!ParsedSource` | Arena-owned |
| `stripUntrustedBlocks` | `fn` (private) | Removes instruction-shaped fenced blocks from body | allocator, body bytes | `!struct{ body, blocks }` | Arena-owned |
| `slugAlloc` | `fn` (private) | Derives a Boris-safe slug from a source filename | allocator, source name | `![]u8` | Arena-owned |
| `emitPage` | `fn` (private) | Serialises one record to Boris-ready Markdown | allocator, Record | `![]u8` | Arena-owned |
| `emitIndex` | `fn` (private) | Emits a collection index stub | allocator, Collection | `![]u8` | Arena-owned |
| `decidedParent` | `fn` (private) | Selects parent value for emitted frontmatter | Record | `?[]const u8` | Borrows from arena |
| `appendParentNormJson` | `fn` (private) | Serialises `ParentNormalization` into JSON buffer | buf, allocator, ParentNormalization | appends to buf | Arena-owned buffer |
| `writeFile` | `fn` (private) | Writes bytes to a path under a Dir, creating parent dirs | Io, Dir, path, data | `!void` | Caller owns data |
| `readFileAlloc` | `fn` (private) | Reads entire file into allocator-owned slice | Io, Dir, path, allocator | `![]u8` | Caller frees |
| `appendJson` | `fn` (private) | JSON-escapes a string into a buffer | buf, allocator, string | appends to buf | Arena-owned buffer |
| `appendUsize` | `fn` (private) | Formats a usize as decimal into a buffer | buf, allocator, value | appends to buf | Arena-owned buffer |

**`run` lifecycle:** Initialises an `ArenaAllocator` over the supplied `gpa`; all per-run allocations go into the arena. The arena is deferred-deinit at function exit (success or error). Opens source root; collects both collections into `records`; sorts; creates output directory; writes index stubs; writes page files; accumulates parent-normalisation counts; constructs manifest and report JSON buffers; writes both. Progress line (unless `--quiet`) is printed via `std.debug.print` after all output is written.

***

## Ownership and lifetime model

All per-run heap allocations flow through an `ArenaAllocator` initialised over the `gpa` in `run`. The arena is deferred-deinit, so all arena-owned memory is freed on function exit (success or error). The `gpa` is not used directly within `filed.zig` after the arena is created — all allocations go through `arena.allocator()`.

`RunOptions` fields (`sourcerootdir`, `outdir`) are `[]const u8` slices pointing into the process argument memory owned by `main`; `filed.zig` does not free them. The `Io` parameter is a value type passed by value; no ownership transfer.

File handles (source dir, output dir, per-file `openFile`) are all deferred-closed. The arena owns all string data (keys, values, paths, JSON buffers, record field slices). There is no separate scratch allocator or buffer pool.

**Lifetime assumptions enforced only by convention:** The `RunOptions` slice fields must remain valid for the duration of `run`. This is enforced by the fact that `main` holds them as `const` slices from the process arg list, but this is not type-enforced by `filed.zig` itself.

**Leak freedom:** Not directly tested with an allocator that detects leaks. The `ArenaAllocator.deinit` releases all arena memory in bulk; individual arena frees are never called. No claim of leak freedom for the `gpa` is warranted without explicit testing.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--filed-root` missing | `main.zig` dispatch | `std.log.err` + usage printed | Exit 2 | None |
| `--out` equals `--filed-root` | `main.zig` guard | `std.log.err` | Exit 2 | None |
| Output inside source root | `filed.run` prefix check | Propagated as `error.OutputInsideSource`; `main` logs + exits 3 | Exit 3 | None |
| Source dir open failure | `filed.run` openDir | Propagated; `main` logs + exits 3 | Exit 3 | None |
| Collection dir open failure | `collectCollection` | Propagated; partial record list | Exit 3 | Possible stale outdir |
| Unreadable source file | `readFileAlloc` | Propagated | Exit 3 | Possible stale outdir |
| `error.UnexpectedCollectionCardinality` | `run` after collection | Propagated; `main` logs + exits 3 | Exit 3 | outdir may have been created |
| Output dir create failure | `Io.Dir.cwd.createDirPath` | Propagated | Exit 3 | None |
| File write failure | `writeFile` | Propagated | Exit 3 | Partial output tree |
| `error.InvalidSourceName` (slug) | `slugAlloc` | Propagated | Exit 3 | Partial output |
| `OutOfMemory` | Arena alloc | Propagated | Exit 3 | Partial output |
| Unknown CLI flag | `parseOptions` in `main.zig` | `std.log.err` + usage | Exit 2 | None |

All user-visible messages are plain `std.log.err` strings or `std.debug.print` for progress. There is no structured diagnostic format beyond what is embedded in `report.json`. Exit codes are 0, 2, or 3 as declared in `main.zig`; exact codes for each error are determined by the `catch` branch in `main.zig`'s `.filed` dispatch, which maps all `filed.run` errors to exit 3.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Imports `filed.zig`; owns CLI parsing and dispatch | Importer → module | `main.zig` owns CLI surface; `filed.zig` owns mode implementation |
| `tools/migration-lab/build.zig` | Compiles both files as single root module | Build integration | `build.zig` owns build contract |
| `tools/migration-lab/fixtures/mini-filed/` | Test input fixture | Test fixture → implementation | Fixture is input evidence |
| `tools/migration-lab/fixtures/filed-parent-normalize/` | Parent-key normalisation test fixture | Test fixture → implementation | Fixture is input evidence |
| `tools/migration-lab/fixtures/filed-parent-conflict/` | Parent-key conflict test fixture | Test fixture → implementation | Fixture is input evidence |
| `tools/migration-lab/README.md` | Documents CLI flags and safety rules | Documentation | Informational; verified against implementation |
| `tools/migration-lab/fixtures/fm-review-open-fence/` | Open-fence stripping fixture | Test fixture | Indirect — used by `stripUntrustedBlocks` path |
| Boris product compiler (`src/`) | No relationship | None | `filed.zig` has no import of product modules |
| Root `build.zig` | No relationship | None | Root build does not reference migration lab |
| Source-RAG output (this pack) | Generated output | Generated from → source | Source is authoritative; pack is derived |


***

## Security and trust boundaries

**Untrusted repository paths:** Source file names come from `dir.iterate()`, which returns OS-level directory entries. `collectCollection` does not validate `entry.name` for traversal sequences before constructing `rel = "src/content/docs/<name>/" + entry.name`. On most operating systems, `iterate()` does not return `.` or `..` as regular file entries, but this is OS-contract behaviour, not a structural guarantee enforced by `filed.zig`. A maliciously crafted filesystem could present an `entry.name` containing `/` on some platforms.

**Arbitrary source-file bytes:** Source file content is read as raw bytes and parsed as YAML-like frontmatter by a hand-written scanner that splits on `:` and skips indented lines. Malformed YAML (e.g. duplicate keys, flow sequences, anchors) is handled by the scanner treating unknown keys as "unmapped" and copying them into the manifest as opaque strings. No YAML parser is used; no code execution risk from source content.

**Markdown fence safety:** `stripUntrustedBlocks` removes instruction-shaped fenced blocks from the body. The stripped block content is not parsed, interpreted, or re-emitted. The removal is based on a line-by-line state machine keyed on fence prefix patterns. An unclosed fence causes the stripper to consume the remainder of the body (documented: `fm-review-open-fence` fixture). Content inside stripped blocks is discarded, not copied to output.

**Embedded frontmatter in packed documents:** The provenance manifest embeds `rawfrontmatter` as a JSON string. The `appendJson` function escapes the standard JSON special characters. The raw frontmatter is treated as an opaque byte string for the manifest; it is not re-parsed.

**Path traversal in parent values:** `isSafeParentId` rejects values containing `/`, spaces, leading/trailing `-`, `.` segments, and `..`. This is a whitelist validator; only `[a-z0-9.\-/]`-equivalent characters at appropriate positions are allowed. The accepted character set is implemented as a closed `for` loop with explicit character range checks.

**Output overwrite:** Existing output files are overwritten without confirmation. There is no check for whether a path under `outdir` could resolve outside `outdir` via symlink.

**Terminal output:** Progress messages are written with `std.debug.print` to stderr. Field values from source frontmatter are embedded in `report.json` (JSON-escaped) but not in progress messages.

**Network exfiltration:** Absent — no network API is imported or callable from this file.

**Resource exhaustion:** `readFileAlloc` uses `.unlimited` size limit. Very large source files will cause large arena allocations. No file-size cap is enforced.

***

## Evidence limitations

- **`tools/migration-lab/build.zig.zon`:** Not available in the source pack. Dependency declarations (if any) are unknown.
- **Exact inline test names and locations:** The source pack renders inline test code intermixed with surrounding module code; precise test boundaries and names within `filed.zig` versus `main.zig` cannot be fully separated from the pack representation alone. Test existence is confirmed; exact scope boundaries are partially certain.
- **Stale-output behaviour:** No test exercises a second run into an existing output directory. The claim that stale files are not deleted is inferred from the absence of any `deleteTree` or `deleteFile` call in `run`.
- **Symlink handling in collection iteration:** Inferred from `entry.kind != .file` guard; actual platform behaviour for symlink-to-file entries is not tested.
- **Cross-platform byte identity:** Not tested; inferred from absence of platform-specific code.
- **Allocation-failure paths:** No allocator-fault injection test exists in the available evidence.
- **Control-character JSON escaping completeness:** `appendJson` explicitly handles `"`, `\`, `\n`, `\r`, `\t`, `\x00`. Characters in `[0x01, 0x1f]` excluding those five are not explicitly handled; they would be passed through as raw bytes into the JSON string, potentially producing non-compliant JSON. This is inferred from reading the `appendJson` source; it is a structural observation, not a tested defect.
- **`docs/MIGRATION.md`:** Referenced in the README as a companion guide; not available in the source pack. Its content is unknown.

***

## Final source assessment

`tools/migration-lab/filed.zig` is a focused, self-contained migration module responsible for exactly one narrow task: converting a Filed.fyi Astro source tree with a known two-collection layout into Boris-ready Markdown with normalised parent keys and a provenance trail. It has no product-compiler dependency and is structurally isolated from the Boris runtime.

**Strongest supported guarantees:** The tool never modifies source files (structurally enforced by write-only output dir handles); it enforces a cardinality contract before writing any output; its parent-key normalisation is a pure, deterministic function well-covered by fixture tests; it performs no network access or subprocess invocation (structurally verified by absence of relevant imports).

**Weakest or least-tested boundaries:** Stale-output cleanup on re-run is absent and untested. The output-inside-source containment guard is a string comparison, not symlink-aware. Allocation-failure paths are untested. The control-character escaping in `appendJson` is incomplete. The cardinality constraint is not exercised by a wrong-count failure fixture.

**Separation from Boris product runtime:** Complete and structurally enforced. No import of any Boris product module exists in the file or in the migration lab's build graph.

**Quality of available evidence:** Good for the happy path and for parent-key normalisation specifically; partial for error paths and stale-output behaviour; uncertain for cross-platform and allocation-fault behaviour.

**Most important unresolved question:** Does the tool's output remain valid input to the Boris product compiler for fixture content beyond the `mini-filed` fixture? The product compiler's closed-frontmatter grammar is not directly tested against filed-mode output in the available evidence.
