---
title: "`tools/migration-lab/theme_materialize.zig` surface and execution"
id: docs/tools/migration-lab/theme_materialize/surface-and-execution
parent: docs/tools/migration-lab/theme_materialize
status: draft
tags: [boris, zig, tools, surface, migration-lab, theme_materialize]
---

# `tools/migration-lab/theme_materialize.zig` surface and execution

## CLI surface

`themematerialize.zig` exposes no CLI surface directly. All argument parsing is done by `main.zig`. The relevant flags dispatched to `themematerialize.run` are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode theme-materialize` | Yes (to enter this mode) | N/A | Also: `materialize`, `theme-materialise` | Selects `themematerialize.run` dispatch | Invalid mode returns exit code 2 |
| `--root &lt;DIR>` | Yes (implicit default `.`) | `.` | Any path | Source theme tree root | If equal to `--out`, rejected with exit code 2 |
| `--ledger &lt;FILE>` | **Yes** | None | Path to `adaptationledger.json` | Passed as `opts.ledgerpath`; absence returns exit code 2 with usage | Missing value → exit 2 |
| `--out &lt;DIR>` | No | `migration-report` | Any path | Output directory; must differ from `--root` and `--ledger` directory | Collision check done in `main.zig` before dispatch |
| `-q`, `--quiet` | No | Off | Boolean flag | Suppresses progress line from `run` | N/A |
| `-h`, `--help` | No | Off | Boolean flag | Print usage, exit 0 | N/A |

`main.zig` enforces that `--out` must differ from both `--root` and `--ledger` before calling `themematerialize.run`. Exact exit codes: `0` success, `2` usage error, `3` IO error. If `run` returns an error, `main.zig` logs `migration-lab theme-materialize failed: <error name>` and returns exit code 3.

***

## Inputs and discovery model

`themematerialize.zig` does not perform its own file discovery. Its inputs are fully determined by two sources:

1. **The archaeology ledger** (`adaptationledger.json`): a JSON array of objects each with `sourcepath`, `category`, `decision`, `proposedborisequivalent`, and `sha256` fields, produced by a prior `theme-archaeology` run. The ledger is assumed to be sorted by source path (this is enforced by `themearchaeology.zig`, not re-verified here).
2. **The source theme tree** (opened from `opts.rootdir`): only files explicitly named in ledger entries with `decision: preserve` are read. No filesystem walk occurs.
| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Archaeology ledger | Read from `opts.ledgerpath` as a whole JSON document | Required | Any ledger not parseable as JSON returns `error.InvalidLedger` | Source: `run` function |
| Ledger entries | Iterated from `entries.array.items` | All entries | Entries with unsafe source paths are refused, not skipped silently | Source: main loop |
| CSS/font/image assets | Only `preserve`-decided entries in those categories | Only if no companion `drop` evidence for same source path | Entries with dropped companion evidence refused | Source: `hasDroppedCompanionEvidence` |
| Layout source | Only `adapt`-decided `layout` category entries | Only first such entry (one layout permitted) | Multiple layout rows refused with explicit status | Source: `layoutwritten` flag |
| License files | Only `preserve`-decided `license` category entries | All matching | None beyond path safety | Source: license branch |
| All other categories | All entries iterated | None actively copied | All other categories result in `skipped` or `refused` status | Source: fall-through `try actions.append` |

Symlink behavior: the source dir is opened with `Io.Dir.openDir`, and `readFile` uses `openFile` — symlink traversal policy depends on the `Io` abstraction and is not explicitly checked within `themematerialize.zig`. The `wordpress.zig` sibling module explicitly checks for symlinks; this module does not. This is a residual gap (see Evidence Limitations).

***

## Output artifact model

All outputs are written to `opts.outdir`. The `run` function creates the output directory and two subdirectories unconditionally before processing:

```
<outdir>/
  theme/
    assets/
      css/
      fonts/
      images/
      (etc. — destination paths from ledger proposedborisequivalent)
    layouts/
      main.html    ← generated layout shell (if an adapt layout row exists)
    LICENSE        ← copied if a preserve license row exists
  materialize-manifest.json
  MATERIALIZE-REPORT.md
  PROVENANCE.md
```

| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `materialize-manifest.json` | Hand-serialized JSON (no `std.json` writer) | Generated, disposable | Ledger entry order (source-path sorted) | Human / downstream tooling | Not versioned per se; `schemaversion: 1`, `toolversion: 0.1.0` in header |
| `MATERIALIZE-REPORT.md` | Markdown table | Generated, disposable | Ledger entry order | Human review | No stability guarantee beyond determinism |
| `PROVENANCE.md` | Markdown table (copied-only rows) | Generated, disposable | Ledger entry order filtered to `status: copied` | Human review | Same as above |
| `theme/assets/…` | Byte-for-byte copy of source files | Generated from source | Source-path order (ledger order) | Boris product compiler theme input | Byte-identical to source if SHA-256 matches |
| `theme/layouts/main.html` | Hand-generated static HTML with closed Boris slot markers | Generated | One file, first adapt layout row wins | Boris product compiler theme layout | Content determined by first proven CSS path in ledger |
| `theme/LICENSE` | Byte-for-byte copy | Generated from source | One file (last `preserve` license row wins if multiple) | Human / legal review | Byte-identical to source |

**Which outputs are required for a minimally useful upload:** `theme/layouts/main.html` and at least one copied CSS asset constitute the minimum Boris-usable theme draft. `materialize-manifest.json` is the canonical machine record. `PROVENANCE.md` is a human convenience. `MATERIALIZE-REPORT.md` is a human convenience summary.

***

## Serialization and schema behavior

`themematerialize.zig` performs all JSON serialization by hand via `appendJson` (which escapes `"`, `\`, `/`, `\r`, `\n`, `\t`, and control characters U+0000–U+001F as `\uXXXX`). It does not use `std.json.stringify`.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `materialize-manifest.json` | `"format": "boris-theme-materialize-lab"`, `"schemaVersion": 1` | `emitManifest` | Ledger entry order | Not validated on read; format declared in header only |
| `MATERIALIZE-REPORT.md` | None | `emitReport` | Ledger entry order | Not machine-validated |
| `PROVENANCE.md` | None | `emitProvenance` | Ledger entry order, `copied` rows only | Not machine-validated |
| Input: `adaptationledger.json` | Parsed via `std.json.parseFromSlice` | `themearchaeology.zig` | Source-path sorted (enforced by producer) | `error.InvalidLedger` if not valid JSON object with `entries` array |

Field ordering in `materialize-manifest.json` is fixed: `format`, `schemaVersion`, `toolVersion`, `sourceRoot`, `actions`, then per-action: `sourcepath`, `destination`, `category`, `decision`, `status`, `detail`, `sha256`. The `sha256` field is `null` (literal JSON null) when empty.

No newline is appended to the final JSON output — the buffer ends with `}`. Markdown reports use `\n` line endings (Zig string literals). No cross-platform newline normalization is applied.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Output ordering | Ledger is source-path sorted by `themearchaeology.zig`; `themematerialize` processes in ledger order without re-sorting | Structurally checked (depends on producer) | If the ledger is produced by a different tool or hand-edited, ordering is unverified |
| Fixed JSON field order | `emitManifest` appends fields in a fixed literal sequence | Directly demonstrated | None within a single Zig version |
| No timestamps in output | No `std.time` or `std.posix.clock_gettime` usage observed | Structurally checked | Uncertain if `Io` abstraction injects time |
| No random identifiers | No `std.Random` usage | Structurally checked | None |
| SHA-256 pre-copy verification | `sha256Hex` computed and compared to ledger value before write; mismatch → `refused` | Directly demonstrated by hostile-fixture test | Ledger SHA field may be empty string; empty string skips mismatch check (passes through) |
| Byte-for-byte determinism | Two-run test compares all named output files byte-for-byte | Directly demonstrated | Only run on `mini-theme-astro` fixture on a single host; cross-platform not tested |
| Duplicate destination prevention | `destinations` ArrayList checked before each copy | Structurally checked | Not tested for case-insensitive collision on case-folding filesystems |
| First CSS path wins for layout | Pre-scan loop selects the first `preserve` CSS with a `theme/assets` destination before layout emission | Structurally checked | If no CSS exists, layout emits without a `<link>` element (empty `csspath`) |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written inside source tree | `archaeology.refuseOutputInsideSource(opts.rootdir, opts.outdir)` called first in `run` | Yes — error returned before any I/O | Uncertain — test coverage of this specific call not observed in `themematerialize` tests | Depends on `themearchaeology.refuseOutputInsideSource` correctness |
| Path traversal via ledger `sourcepath` | `isSafeRelativePath` rejects paths starting with `/`, containing `\0`, containing `\\`, or containing `..` segments | Yes — applied to every source path before open | Directly tested: `test "theme materialize refuses unsafe ledger paths"` | Absolute paths on Windows (e.g., `C:\`) not explicitly handled by the check |
| Path traversal via `proposedborisequivalent` (destination) | `isSafeRelativePath` applied to extracted destination after `markerPath` extraction | Yes | Hostile fixture test confirms remote-ref CSS not written | `markerPath` stops at first whitespace, quote, or newline; malicious ledger values with unusual Unicode not tested |
| Duplicate destination overwrite | `destinations` list checked; second write is refused | Yes | Hostile fixture | Case-insensitive collision on case-folding filesystems not tested |
| Symlink in source tree | Not explicitly checked in this module | No — depends on `Io.Dir.openFile` behavior | Not tested | Potential gap vs. `wordpress.zig` which explicitly rejects symlinks |
| Output directory creation failure | `createDirPath` errors propagate as `!void` | Yes (Zig error propagation) | Not directly tested | Partial output state if directory creation partially succeeds |
| Stale output from previous run | No cleanup of previous output; new files overwrite, old files remain | Not enforced | Not tested | Previous valid output can contain stale files not produced by current ledger |
| Unsafe ledger path (absolute) | `isSafeRelativePath` checks `path[^1_0] == '/'`; also checks `path[^1_0] == '\\'` | Yes for POSIX-style | Windows absolute paths with drive letters may not be caught | Residual |

Note: the module uses `std.mem.eql` string comparison for collision checking, not case-folding. On a case-insensitive filesystem (macOS HFS+, Windows NTFS), two ledger entries for `theme/assets/css/Site.css` and `theme/assets/css/site.css` would not be detected as a collision but would resolve to the same file.

***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const []u8` | Schema identity string for output JSON | — | `"boris-theme-materialize-lab"` | Static |
| `schema_version` | `pub const u32` | Schema version for output JSON | — | `1` | Static |
| `tool_version` | `pub const []u8` | Tool version string for output JSON | — | `"0.1.0"` | Static |
| `Options` | `pub const struct` | Run parameters (rootdir, outdir, ledgerpath, quiet) | — | Type definition | — |
| `Action` | `const struct` | Per-ledger-entry result record | — | Type for manifest/report | Arena-owned |
| `jsonString` | `fn` | Extract string field from `std.json.Value` | JSON value, key | `[]const u8` or `""` | Borrowed from parsed JSON |
| `hasSegmentTraversal` | `fn` | Check for `..` path segments | Path string | `bool` | — |
| `isSafeRelativePath` | `fn` | Combined path safety check | Path string | `bool` | — |
| `startsWithDecision` | `fn` | String equality for decision field | decision, expected | `bool` | — |
| `hasDroppedCompanionEvidence` | `fn` | Scan ledger for `drop` entry with same source path | entries slice, sourcepath | `bool` | Borrowed from parsed JSON |
| `markerPath` | `fn` | Extract `theme/assets/…` or `theme/layouts/…` path from `proposedborisequivalent` | proposed string, marker | `?[]const u8` | Slice into input string |
| `appendJson` | `fn` | JSON-escape and append a string value | buffer, allocator, value | Appends to buffer | Arena-owned buffer |
| `ensureParent` | `fn` | Create parent directories for a relative path | Io, root dir, rel path | Directory tree created | — |
| `writeBytes` | `fn` | Write a byte slice to a relative path under a dir | Io, root dir, rel, data | File written | — |
| `readFile` | `fn` | Read a file fully into an allocated buffer | Io, root dir, path, allocator | `[]u8` | Caller-owned (arena) |
| `emitLayout` | `fn` | Generate closed static HTML layout shell | allocator, csspath | `[]u8` HTML | Arena-owned |
| `emitManifest` | `fn` | Serialize `materialize-manifest.json` | allocator, sourceroot, actions | `[]u8` JSON | Arena-owned |
| `emitReport` | `fn` | Serialize `MATERIALIZE-REPORT.md` | allocator, actions | `[]u8` Markdown | Arena-owned |
| `emitProvenance` | `fn` | Serialize `PROVENANCE.md` | allocator, root, actions | `[]u8` Markdown | Arena-owned |
| `run` | `pub fn` | Main execution entry point | Io, gpa allocator, Options | `!void` | — |

### `run` function

- **Initialization**: calls `archaeology.refuseOutputInsideSource(opts.rootdir, opts.outdir)` immediately; returns `error.UnsafePath` if the ledger path is unsafe and not absolute.
- **Allocator setup**: creates an arena over `gpa`; all per-run allocations use the arena allocator `a`; the arena is deferred-deinitialized.
- **I/O setup**: opens source dir via `Io.Dir.cwd.openDir(io, opts.rootdir)`; opens/creates output dir; creates `theme/assets` and `theme/layouts` subdirectories.
- **Ledger loading**: reads the ledger file into the arena; parses as `std.json.Value`; returns `error.InvalidLedger` if not an object with an `entries` array.
- **Pre-scan for CSS path**: iterates all entries to find the first `preserve` CSS entry with a safe `theme/assets` destination and no dropped companion evidence, to resolve `csspath` before layout emission.
- **Main loop**: iterates all ledger entries, applies refusal policy, copies or generates files, builds `actions` slice.
- **Report emission**: writes `materialize-manifest.json`, `MATERIALIZE-REPORT.md`, `PROVENANCE.md` to the output root.
- **Cleanup**: arena deinit frees all temporary allocations. Source dir and output dir are closed via `defer`.
- **Exit**: returns `void` on success; returns first encountered error on failure (propagated as Zig error union).

***

## Ownership and lifetime model

- **Arena allocator** (`a`): wraps `gpa`; deferred-deinit at end of `run`. All per-run allocations (ledger bytes, JSON parse tree, action strings, manifest bytes, report bytes) live in the arena.
- **`gpa`**: passed in from `main.zig`; used only to initialize the arena. No direct `gpa` allocations inside `run`.
- **`actions` ArrayList** and **`destinations` ArrayList**: allocated in the arena; no separate deinit needed (arena wipe covers them).
- **Ledger JSON parse tree** (`parsed`): `defer parsed.deinit` is present — this is necessary because `std.json.parseFromSlice` may allocate hash map nodes. The `defer` fires before arena deinit, which is correct.
- **Source and output `Io.Dir` handles**: closed via `defer` in `run`.
- **File body bytes** (`readFile` results): arena-owned; freed with arena.
- **SHA-256 hex strings** (`sha256Hex`): arena-owned.
- **Emitted byte buffers** (`emitManifest`, `emitReport`, `emitProvenance`): arena-owned; written to disk then implicitly freed with arena.

No lifetime assumptions enforced only by convention were identified. The `defer parsed.deinit` pattern is structurally correct. The arena wipe on error path releases all in-progress allocations, but partially written output files under `outdir` are not cleaned up on error — a subsequent valid run would overwrite them, but stale files from a failed partial run may remain.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--ledger` not provided | `main.zig` CLI parse | `"theme-materialize mode requires --ledger FILE"` + usage | Exit 2 | None |
| `--out` == `--root` or `--out` == `--ledger` | `main.zig` pre-dispatch | `"--out must differ from --root and --ledger"` | Exit 2 | None |
| Output inside source | `refuseOutputInsideSource` | Propagated as `error.UnsafePath` → `main.zig` logs error name | Exit 3 | None |
| Ledger file not found | `readFile` returns error | `error.LedgerNotFound` → `main.zig` logs | Exit 3 | Output dir may have been created |
| Invalid ledger JSON | `std.json.parseFromSlice` or shape check | `error.InvalidLedger` → `main.zig` logs | Exit 3 | Output dir and subdirs may exist |
| Source file unavailable | `readFile(source, sourcepath)` fails | `action.status = "refused"`, `detail = "source file unavailable"` | **Continues** — no abort; logged in manifest | Yes — partial output |
| SHA-256 mismatch | `sha256Hex` compare | `action.status = "refused"`, `detail = "source bytes do not match ledger sha256"` | **Continues** | Yes |
| Unsafe source path | `isSafeRelativePath` | `action.status = "refused"`, `detail = "unsafe source path"` | **Continues** | Yes |
| Unsafe destination | `isSafeRelativePath` on destination | `action.status = "refused"`, `detail = "unsafe materialized destination"` | **Continues** | Yes |
| Duplicate destination | `destinations` check | `action.status = "refused"`, `detail = "duplicate destination"` | **Continues** | Yes |
| Dropped companion evidence | `hasDroppedCompanionEvidence` | `action.status = "refused"`, `detail = "source has dropped remote or unsafe dependency evidence"` | **Continues** | Yes |
| Multiple layout rows | `layoutwritten` flag | `action.status = "refused"`, `detail = "multiple layout rows cannot silently overwrite main.html"` | **Continues** | Yes |
| Output write failure | `writeBytes` propagates error | Zig error propagates to `run` → `main.zig` logs | Exit 3 | Yes — partial output |
| Allocation failure | `!void` propagation | Zig error propagates | Exit 3 | Yes |

All per-entry refusals are non-fatal and recorded in `actions`; the manifest and reports are written at the end regardless. IO write failures for final reports are fatal. There is no structured stderr diagnostic format; errors logged by `main.zig` use `std.log.err` (plain stderr).

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Dispatcher; imports this module; handles all CLI; pulls this module's tests into the test binary | Inbound (main imports this) | `main.zig` owns CLI and dispatch |
| `tools/migration-lab/themearchaeology.zig` | Imported implementation (`archaeology.refuseOutputInsideSource`, `archaeology.sha256Hex`); also produces the ledger consumed at runtime | Inbound (this imports archaeology) | `themearchaeology.zig` owns ledger format |
| `tools/migration-lab/build.zig` | Compilation and test step | Build configuration | `build.zig` owns build |
| `tools/migration-lab/fixtures/mini-theme-astro/` | Test fixture (happy path) | Input to tests | Fixture files are test inputs |
| `tools/migration-lab/fixtures/hostile-theme-astro/` | Test fixture (adversarial) | Input to tests | Fixture files are test inputs |
| `tools/migration-lab/README.md` | Documents the `--mode theme-materialize` workflow and safety rules | Documentation | README documents intent |
| `adaptationledger.json` (runtime, under `--out` of prior `theme-archaeology` run) | Runtime input (ledger); produced by `themearchaeology.run` | Runtime data flow | `themearchaeology.zig` owns the schema |
| Root `build.zig` | Not included | None | Root build does not cover this tool |
| Boris `src/` product compiler | Not imported; not linked | None | Complete separation |


***

## Security and trust boundaries

- **Untrusted ledger paths**: `sourcepath` fields in the ledger are from a prior archaeology run over potentially untrusted source. `isSafeRelativePath` validates them before use. Bypasses: Windows drive-letter paths; POSIX paths with unusual Unicode separators; null bytes (checked via `\0` test).
- **Arbitrary source file bytes**: files are read and copied opaque-byte without parsing. The SHA-256 is verified against the ledger value. If the ledger was produced by an honest archaeology run, this provides integrity; if the ledger was hand-crafted, the SHA field may be empty (skipping verification) or forged.
- **`proposedborisequivalent` field**: used as the destination path. `markerPath` extracts only the substring from `theme/assets` or `theme/layouts` up to the first whitespace/quote/newline. This is not a full URL-safe sanitization; ledger values with embedded sequences that survive the extraction are then checked by `isSafeRelativePath`. Ledgers containing carefully crafted `proposedborisequivalent` values with legal-looking paths but pointing to sensitive output locations are theoretically possible if the ledger is hand-edited.
- **Markdown fence safety**: `MATERIALIZE-REPORT.md` and `PROVENANCE.md` embed `sourcepath` and `destination` values from the ledger directly into Markdown table cells. No fencing or escaping of Markdown metacharacters is applied. A ledger entry with `|` in a source path would visually corrupt the Markdown table but would not cause code execution.
- **No network**: no network access or subprocess invocation is present.
- **Output overwrite**: existing files at output destinations are overwritten without comparison. Previous valid outputs under `outdir` are not preserved; no atomic replacement.
- **Resource exhaustion**: very large source files are read entirely into the arena before copying. No streaming or size limit is applied. A very large file in a ledger entry would exhaust arena memory. No evidence this is bounded.
- **Terminal output**: progress print uses `std.debug.print`, which does not escape the output directory string. A path containing ANSI escape sequences would be emitted to the terminal verbatim.

***

## Evidence limitations

- **`tools/migration-lab/build.zig`**: the full build file was not read in this investigation. The README confirms `zig-out/bin/boris-migration-lab` as the output and `zig build test` as the test command. Build option details (target, optimization flags, build steps) are uncertain.
- **`tools/migration-lab/build.zig.zon`**: not inspected. Dependency declarations, minimum Zig version constraints, and package hash are uncertain.
- **Symlink policy**: `wordpress.zig` explicitly rejects symlinks with `isSymlink` checks. `themematerialize.zig` does not perform equivalent checks. Whether the `Io.Dir.openFile` abstraction follows symlinks is uncertain.
- **Windows absolute path safety**: `isSafeRelativePath` checks for leading `/` and `\\`. Windows drive-letter paths (`C:\...`) would not be caught. Whether the tool is expected to run on Windows is uncertain.
- **Arena allocator behavior on failure**: Zig arenas do not return `error.OutOfMemory` in all configurations; behavior on allocation failure depends on the backing allocator. The `gpa` in tests is `std.testing.allocator`; in production it is the GPA from `std.process.Init`. Neither is guaranteed allocation-safe under adversarial large inputs.
- **`refuseOutputInsideSource` implementation**: called from `themearchaeology.zig`. Its exact behavior (prefix check? canonical path? symlink resolution?) was not verified in this investigation.
- **Cross-platform CI**: no CI configuration was inspected. All tests are observed to run on the developer host. Cross-platform byte identity is unverified.
- **Schema version evolution**: `schemaVersion: 1` is declared but there is no version-checking code on the ledger input side. What happens when a `schemaVersion: 2` ledger is fed to this tool is undefined.
- **Empty `sha256` field bypass**: the source explicitly shows `if (recordedsha.len > 0 and !std.mem.eql(u8, recordedsha, actualsha))` — an empty SHA field skips verification and allows copy. This behavior is present in the source but not tested as a distinct case.

***

## Final source assessment

`themematerialize.zig` is a narrow, well-bounded implementation module responsible for the second step of the Boris theme migration workflow: consuming an archaeology ledger and producing a safe, human-reviewable Boris theme draft. Its strongest guarantees — demonstrated directly by tests — are: byte-for-byte output determinism on a single host given the same ledger, source tree immutability, and refusal of unsafe or dependency-tainted assets. Its weakest boundaries are stale-output accumulation across re-runs, symlink handling in source reads (not explicitly checked, unlike the `wordpress.zig` sibling), and the empty-SHA-field bypass that skips integrity verification.

Separation from Boris product runtime is complete and structurally enforced: the module is not imported from `src/`, is not included in the root `build.zig`, and writes exclusively to the configured output directory. The test suite provides meaningful evidence for the core copy and refusal logic but leaves cross-platform behavior, allocation failure paths, and stale-output state unverified. The most important unresolved question is whether `Io.Dir.openFile` follows symlinks and whether that is consistent with the security intent of the other migration-lab modules.
