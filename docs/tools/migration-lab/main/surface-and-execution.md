---
title: "`tools/migration-lab/main.zig` surface and execution"
id: docs/tools/migration-lab/main/surface-and-execution
parent: docs/tools/migration-lab/main
status: draft
tags: [boris, zig, tools, surface, migration-lab, main]
---

# `tools/migration-lab/main.zig` surface and execution

## CLI surface

| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--help` / `-h` | No | false | — | Prints usage text, exits 0 | — |
| `--quiet` / `-q` | No | false | — | Suppresses progress lines | — |
| `--mode MODE` | No | `astro` | See Mode enum + aliases below | Selects migration mode | `error.InvalidValue` → exit 2 |
| `--out DIR` | No | `migration-report` | Any non-empty string | Output directory path | `error.MissingValue` → exit 2 |
| `--root DIR` | No | `.` | Any non-empty string | Astro/Starlight/theme project root | `error.MissingValue` → exit 2; must differ from `--out` |
| `--wxr FILE` | Yes (wordpress) | null | Non-empty path | WordPress WXR XML file; implies `--mode wordpress` | Missing → usage error + exit 2 |
| `--media DIR` | No | null | Non-empty path | WordPress media directory; must differ from `--out` | `error.MissingValue` → exit 2 |
| `--dump DIR` | No | null | Non-empty path | Instagram dump root; implies `--mode instagram` | Missing for instagram mode → usage error + exit 2 |
| `--vault DIR` | No | null | Non-empty path | Obsidian vault root; implies `--mode obsidian` | Missing for obsidian mode → usage error + exit 2 |
| `--export DIR` | No | null | Non-empty path | Notion export root; implies `--mode notion` | Missing for notion mode → usage error + exit 2 |
| `--filed-root DIR` | No | null | Non-empty path | Filed.fyi Astro root; implies `--mode filed` | Missing for filed mode → usage error + exit 2 |
| `--locale KEY` | No | `en` | Non-empty string (`en` only supported) | Starlight locale key | Non-`en` → `error.LocaleNotSupported` in `starlight.run` |
| `--max-pages N` | No | `40` | Positive integer, parsed as `usize` | Cap on Starlight converted pages | Non-numeric → `error.InvalidValue` → exit 2; out-of-range caught in `starlight.run` |
| `--boris PATH` | No | null | Non-empty path | Path to Boris binary for Starlight compile verification | Binary not found → compile step skipped (not an error) |
| `--ledger FILE` | No | null | Non-empty path | `adaptationledger.json` from theme-archaeology | Missing for theme-materialize mode → usage error + exit 2 |
| `--content DIR` | No | null | Non-empty path | Content tree root; implies `--mode frontmatter-review` | Missing for frontmatter-review mode → usage error + exit 2 |
| Unknown flags | — | — | — | `error.UnknownFlag` → exit 2 + usage hint | — |
| Missing value | — | — | — | `error.MissingValue` → exit 2 + usage hint | — |

**Mode aliases** (resolved by `Mode.parse`):

- `wordpress` | `wp` | `wxr` → `.wordpress`
- `instagram` | `ig` | `takeout` → `.instagram`
- `obsidian` | `obs` | `vault` → `.obsidian`
- `notion` | `md-csv` | `notion-export` → `.notion`
- `filed` | `filed-fyi` → `.filed`
- `starlight` | `sl` | `evcc` → `.starlight`
- `asset-filename` | `assets` | `asset-compat` | `filename-compat` → `.assetfilename`
- `theme-archaeology` | `theme` | `theme-arch` | `theme-inventory` → `.themearchaeology`
- `theme-materialize` | `theme-materialise` | `materialize` → `.themematerialize`
- `wordpress-theme` | `wp-theme` | `kubrick-theme` → `.wordpresstheme`
- `link-audit` | `links` | `output-audit` → `.linkaudit`
- `frontmatter-review` | `fm-review` | `fmreview` → `.frontmatterreview`

**Exit codes:** `0` = success, `2` = usage error, `3` = I/O error. Exact codes defined by the `ExitCode` enum and verified in usage comments; not directly tested by automated assertions.

**Fused vs split flag forms:** Both `--flag=value` (fused, via `std.mem.startsWith`) and `--flag value` (split, via next-argument consumption) are supported for every flag that takes a value. This is directly tested.

***

## Inputs and discovery model

Each mode's discovery logic lives in its own module. `main.zig` contributes only the input root paths resolved from CLI arguments. The following describes the `astro` mode (the one with the most test coverage visible in this file) as the representative example; other modes follow their own module contracts.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Astro `src/content/**/*.md` and `*.mdx` | Recursive walk from `rootdir`; `isContentPage` predicate | Yes | `src/pages/*.astro`, free-form Markdown outside content roots, dotfiles | Tests: `mini-astro`, `root-content-astro`, `dual-content-roots-astro` fixtures |
| Root-level `content/**/*.md` | `contentRootPrefix` discovers both `src/content` and `content` prefixes | Yes | `NOTES.md` and other free-form Markdown outside recognized roots | Test: `root-content-astro` fixture |
| `public/**` assets | Enumerated for asset inventory; existence proven for SHA-256 | Yes | Directories in skip list | Structural: `listPublicAssets` in `archaeology.zig` |
| `src/assets/**` | Enumerated for local asset inventory | Yes | Skip dirs | Structural |
| `astro.config.mjs` / `.ts` / `.js` | Sidebar evidence scan | Yes, if present | Not required | Structural: `scanSidebarEvidence` |
| WordPress WXR file | Single file path from `--wxr` | Required | — | CLI; `main.zig` null-checks |
| WordPress media directory | Optional directory from `--media` | No | — | CLI; null-checked per mode |
| Instagram dump root | Directory from `--dump` | Required | `.yourinstagramactivity/content` or `content/` sub-paths | `instagram.zig` |
| Obsidian vault root | Directory from `--vault` | Required | `.obsidian/` config dir, hidden dirs | `obsidian.zig` |
| Notion export root | Directory from `--export` | Required | — | `notion.zig` |
| Filed.fyi Astro root | Directory from `--filed-root` | Required | — | `filed.zig` |
| Starlight project root | `--root` (default `.`) | Yes | Non-`en` locale siblings when `skipLocaleSiblings` | `starlight.zig` |
| Content tree for frontmatter-review | `--content` | Required | — | `frontmatterreview.zig` |
| Generated HTML tree for link-audit | `--root` | Required | External, mailto, tel, data, hash-only links | `linkaudit.zig` |

Symlink handling: the `walkTree` function in `themearchaeology.zig` marks symlinks as `isSymlink: true` and drops them from processing (decision: `.drop`, reason: `symlink`). Whether every mode's walker similarly handles or rejects symlinks is uncertain for modes beyond `themearchaeology`.

Path ordering: the `astro` mode sorts discovered paths with `std.mem.sort` using lexicographic comparison before processing. This is directly tested for determinism via two-run byte comparison.

***

## Output artifact model

Output varies by mode. The following lists artifacts visible in `main.zig`'s usage text and confirmed by tests.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `report.json` | JSON, mode-specific schema | `--out` dir | Lexicographic source-path sort (astro: tested) | Human review, LLM notebooks | Not versioned per artifact; schema field names visible in tests |
| `REPORT.md` | Markdown | `--out` dir | Same as `report.json` | Human reviewer | Not formally versioned |
| `content/*.md` | Boris-compatible Markdown | `--out` dir | Entity-ID–sorted (starlight); alphabetic (others: uncertain) | Human editor; then Boris product compiler | Not stable across tool versions |
| `mediamanifest.json` | JSON | `--out` dir | Source-path sort | Enrichment pass | Not versioned |
| `adaptationledger.json` | JSON (`boris-theme-archaeology-ledger`) | `--out` dir | class/sourcepath/detail sort (materialize); uncertain for archaeology output | `theme-materialize` mode as input | Identifier present but no schema version field confirmed |
| `routemap.json` | JSON (`format: "boris-starlight-route-map"`, `schemaVersion: 1`) | `--out` dir | Entity-ID sort | Developer review | Schema version declared |
| `unsupportedmanifest.json` | JSON (`format: "boris-starlight-unsupported"`, `schemaVersion: 1`) | `--out` dir | Source-path sort | Developer review | Schema version declared |
| `assetsmanifest.json` | JSON | `--out` dir | Source-path sort | Developer review | Not versioned |
| `selectionmanifest.json` | JSON | `--out` dir | Lexicographic | Developer review | Not versioned |
| `boundarymanifest.json` | JSON | `--out` dir | class/sourcepath/detail sort | Developer review | Not versioned |
| `compilereport.json` | JSON | `--out` dir | N/A (single record) | Developer CI | Not versioned |
| `frontmatterreview.json` | JSON | `--out` dir | Source-path sort | Developer review | Not versioned |
| `inventory.json` (wordpress-theme) | JSON (`format: "boris-wordpress-theme-inventory"`, `schemaVersion: 1`) | `--out` dir | File sort (`fileLess`) | Developer review | Schema version declared |
| `slotmapping.json` | JSON (`format: "boris-wordpress-theme-static-prototype"`, `schemaVersion: 1`) | `--out` dir | Fixed | Developer review | Schema version declared |
| `manualreview.json` | JSON (`format: "boris-wordpress-theme-manual-review"`, `schemaVersion: 1`) | `--out` dir | Signal sort | Developer review | Schema version declared |
| `prototypemain.html` | Static HTML | `--out` dir | Fixed template | Developer review | Not versioned |
| `linkaudit.json` | JSON | `--out` dir | Uncertain | Developer review | Not versioned |
| `theme/` (instagram, starlight) | Directory of layout + CSS shell | `--out` dir | N/A | Developer review | Not versioned |
| `BOUNDARY.md` | Markdown | `--out` dir | Same as ledger | Human reviewer | Not versioned |

**Stale-output cleanup:** No evidence of stale-output deletion in `main.zig` or in the modules read. Each `run` call creates the output directory if missing (`Io.Dir.cwd.createDirPath`) and writes files directly. Previous output in `--out` is overwritten file-by-file; files from a previous run that no longer appear in the new run are **not** deleted. This is not tested.

**Canonical vs convenience:** `report.json` and sidecar manifests are canonical machine records. `REPORT.md` is a human convenience mirror. Neither is part of the Boris product release contract.

***

## Serialization and schema behavior

All machine-readable output is hand-serialized JSON using append-based `std.ArrayList(u8)` builders. No standard library JSON encoder is used. String values are escaped with a local `appendJson` / `jsonEscapeAppend` function; boolean values with `appendBool`. No schema validation library is used.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` (astro) | `"format": "boris-astro-migration-lab"`, `"schemaVersion": 1` | `archaeology.zig` | Lexicographic source path | Test checks key presence, not full schema |
| `routemap.json` | `"format": "boris-starlight-route-map"`, `"schemaVersion": 1` | `starlight.zig` | Entity-ID sort | Test checks key presence |
| `unsupportedmanifest.json` | `"format": "boris-starlight-unsupported"`, `"schemaVersion": 1` | `starlight.zig` | Source-path sort | Test checks key presence |
| `inventory.json` (wordpress-theme) | `"format": "boris-wordpress-theme-inventory"`, `"schemaVersion": 1` | `wordpresstheme.zig` | `fileLess` sort | Test checks key presence |
| `slotmapping.json` | `"format": "boris-wordpress-theme-static-prototype"`, `"schemaVersion": 1` | `wordpresstheme.zig` | Fixed | Test checks key presence |
| `manualreview.json` | `"format": "boris-wordpress-theme-manual-review"`, `"schemaVersion": 1` | `wordpresstheme.zig` | Signal sort | Test checks key presence |
| `mediamanifest.json` (instagram) | `"format": "boris-instagram-media-manifest"`, `"schemaVersion": 1` | `instagram.zig` | Source sort | Test checks key presence |
| Other manifests | No format identifier observed in evidence | Mode-specific | Mode-specific | Test checks key presence only |

**Newline policy:** Files end with `\n` per builder patterns observed. Not independently tested.

**Empty arrays:** Emitted as `[]` (inferred from builder logic). Not tested as a specific case.

**Version disagreement:** No compatibility layer observed. Schema version fields are written but not read by this tool; no migration path exists.

**Parsing and emission:** Parsing of input (WXR XML, JSON, Markdown frontmatter) uses mode-specific parsers in the subordinate modules. No shared schema definition or round-trip test is present.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable astro report JSON across two runs | Lexicographic sort of discovered source paths; deterministic `report.json` builder | Directly demonstrated (byte-equality test: `test "astro fixture scan produces stable report sections"`) | Not tested cross-platform |
| Stable astro REPORT.md across two runs | Same sort + builder | Directly demonstrated (byte-equality test) | Not tested cross-platform |
| Stable root-content-astro output across two runs | Two-run byte comparison on `report.json` | Directly demonstrated | Not tested cross-platform |
| Input immutability (astro mode) | Test reads fixture file before and after `run`; compares bytes | Directly demonstrated | Not tested for other modes in this file |
| Stable wordpress-theme output across two runs | Two-run byte comparison across all output files | Directly demonstrated (fixture `mini-wordpress-kubrick`) | Not tested cross-platform |
| Boundary item sort (theme-materialize) | `class`/`sourcepath`/`detail` triple sort in `buildBoundaryItems` | Structurally checked | Not separately tested |
| Entity-ID sort (starlight pages) | `std.mem.sort` by `entityid` before output | Structurally checked | Not separately byte-compared in a two-run test visible in this file |
| Absence of timestamps in JSON output | Not observed in any builder; no `std.time` calls in evidence | Uncertain — not tested | Cannot confirm for all modes |
| Absence of random identifiers | No RNG calls observed; entity IDs derived from paths or content | Structurally checked | Uncertain for modes not fully read |
| Cross-platform byte identity | Not tested | Uncertain | Platform path separators, filesystem enumeration order |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into input tree | `main` checks string equality of `--out` vs every named input | Yes (string equality in `main`) | Not explicitly tested with a path-equality fixture | Does not catch containment, symlink aliasing, or canonicalization differences |
| Path traversal in source paths | `isSafeMediaUri` in `instagram.zig` refuses URIs with traversal patterns; `hasTraversal` in `themearchaeology.zig` refuses traversal CSS imports | Partially (mode-specific) | Instagram: structural (no dedicated test visible); `hostile-asset-filenames` fixture tests sanitization behavior | Not all modes have visible traversal rejection tests in `main.zig` |
| Symlink traversal | `walkTree` in `themearchaeology.zig` marks symlinks and drops them | Partially (theme-archaeology module) | `symlink.md` fixture in `hostile-asset-filenames` | Other modes' symlink behavior uncertain |
| Accidental recursion into own output | `refuseOutputInsideSource` in mode modules (e.g. `wordpresstheme.zig` exports this as `pub fn`) | Partially (module-level, not all modes) | `wordpresstheme` module has this check; `starlight.run` calls `refuseOutputInsideSource` | Not confirmed for every mode |
| Stale output left from previous run | No cleanup observed | No | No | Previous output files not matching new run persist silently |
| Cleanup on failure | No explicit cleanup on `run` error return | No | No | Partial output may remain after `ExitCode.ioerror` |
| Cross-filesystem behavior | Not addressed | No | No | Uncertain |
| Permissions / unreadable files | `catch continue` observed in `walkTree` (skips unreadable files silently) | Partial | No | Silent skip may omit material without warning |
| Output-path containment (not just equality) | Not implemented in `main`; depends on caller supplying non-overlapping paths | No — only string equality | No | `--out ../sibling` could still overlap with `--root .` in edge cases |


***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `ExitCode` | `enum(u8)` | Typed exit codes: `success=0`, `usage=2`, `ioerror=3` | — | `u8` via `.int()` | Process lifetime |
| `ExitCode.int` | `fn(self) u8` | Convert enum to integer for process exit | `self` | `u8` | — |
| `Mode` | `enum` | All 13 supported migration modes | — | Used by `Options` and dispatch switch | Process lifetime |
| `Mode.parse` | `fn(s: []const u8) ?Mode` | Parse mode string including aliases | String | `?Mode` | — |
| `Options` | `struct` | All parsed CLI options with defaults | — | Used by `main` dispatch | Arena lifetime (copied from args) |
| `ParseError` | `error` set | `UnknownFlag`, `MissingValue`, `InvalidValue` | — | Returned by `parseOptions` | — |
| `parseOptions` | `fn(args: []const []const u8) ParseError!Options` | Hand-rolled CLI argument parser | Argument slice | `Options` or `ParseError` | Borrows arg strings; `Options` holds slices into args |
| `printUsage` | `fn() void` | Print usage text to stderr via `std.debug.print` | — | stderr output | — |
| `main` | `fn(init: std.process.Init) u8` | Process entry; initializes allocators, parses args, dispatches | `std.process.Init` (arena, gpa, io, args) | Process exit code (u8) | Top-level; cleans up via `defer` |

**`main` detail:**

- Uses `init.arena.allocator()` as `cold` (cold-path arena for argument parsing), `init.gpa` for delegated module allocation, and `init.io` for I/O abstraction.
- Argument collection: `init.minimal.args.toSlice(cold)` — failure returns `ExitCode.usage`.
- Argument strings are appended to a local `std.ArrayList([]const u8)` and then passed to `parseOptions`.
- `parseOptions` errors are mapped to `ExitCode.usage` with a brief stderr message and usage text.
- After `opts.help`, prints usage and returns `ExitCode.success`.
- Per-mode: checks that `--out` differs from named inputs; calls `<module>.run(io, gpa, opts)`.
- On `run` error: logs `std.log.err("migration-lab <mode> failed: {s}", .{@errorName(err)})` and returns `ExitCode.ioerror`.
- On success: returns `ExitCode.success`.
- No explicit arena cleanup at exit (defer handles it via `std.process.Init` contract).

***

## Ownership and lifetime model

- **`cold` arena** (`init.arena.allocator()`): used for argument collection and `parseOptions` string slices. Freed automatically at process exit via `std.process.Init` arena contract.
- **`gpa`** (`init.gpa`): passed directly to each mode's `run(io, gpa, opts)`. Each mode is responsible for its own arena wrapping of `gpa`. `main.zig` does not wrap `gpa` in an arena.
- **`opts` struct**: fields are slices borrowed from `argslist.items` (which borrows from cold arena). The `Options` struct holds `[]const u8` slices, not owned copies. Lifetime is valid for the duration of `main` before cold arena cleanup.
- **`argslist`**: `defer argslist.deinit(cold)` — freed at end of `main`.
- **Mode run functions**: each allocates its own arena from `gpa` and is responsible for full cleanup. `main.zig` does not track or free allocations made inside `run`.
- **Leak freedom**: not tested at the `main.zig` level via an allocator wrapper. Instagram module is explicitly excluded from `refAllDecls` in tests because it leaks under the testing allocator.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Unknown CLI flag | `parseOptions` | `std.log.err("unknown argument…")` + usage text | Exit 2 | None (before any `run`) |
| Missing flag value | `parseOptions` | `std.log.err("missing value…")` + usage text | Exit 2 | None |
| Invalid mode string | `parseOptions` | `std.log.err("invalid flag value…")` + usage text | Exit 2 | None |
| `--out` equals input path | `main` dispatch, per-mode | `std.log.err("--out must differ from --<flag>…")` | Exit 2 | None |
| Required mode-specific flag missing (e.g., `--wxr` for wordpress) | `main` dispatch | `std.log.err("<mode> mode requires --<flag>")` + usage text | Exit 2 | None |
| Failed to read process arguments | `init.minimal.args.toSlice` | `std.log.err("failed to read process arguments")` | Exit 2 | None |
| Out of memory during arg parsing | `argslist.ensureTotalCapacity` | `std.log.err("out of memory parsing arguments")` | Exit 2 | None |
| `run` returns any error | `main` dispatch catch | `std.log.err("migration-lab <mode> failed: <errorName>")` | Exit 3 | Likely — output dir and some files may exist |
| Invalid `--locale` (not `en`) | `starlight.run` | Error propagated to `main`; logged as `ioerror` | Exit 3 | Possible |
| Invalid `--max-pages` (non-numeric) | `parseOptions` | Exit 2 | None | None |
| Source not found | Mode `run` (e.g., `error.SourceNotFound` in `wordpresstheme.run`) | Propagated, logged | Exit 3 | Minimal |
| Output creation failure | Mode `run` | Propagated, logged | Exit 3 | None or minimal |

All user-visible diagnostics are plain `std.log.err` / `std.debug.print` stderr messages. No structured error output (JSON or otherwise) is produced by `main.zig`. The exact format of log messages is not tested.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/archaeology.zig` | Imported implementation (`astro` mode) | `main.zig` → `archaeology` | `archaeology.zig` owns discovery, parsing, output |
| `tools/migration-lab/wordpress.zig` | Imported implementation (`wordpress` mode) | `main.zig` → `wordpress` | `wordpress.zig` owns WXR parsing and output |
| `tools/migration-lab/instagram.zig` | Imported implementation (`instagram` mode) | `main.zig` → `instagram` | `instagram.zig` owns dump parsing and output |
| `tools/migration-lab/obsidian.zig` | Imported implementation (`obsidian` mode) | `main.zig` → `obsidian` | `obsidian.zig` |
| `tools/migration-lab/notion.zig` | Imported implementation (`notion` mode) | `main.zig` → `notion` | `notion.zig` |
| `tools/migration-lab/filed.zig` | Imported implementation (`filed` mode) | `main.zig` → `filed` | `filed.zig` |
| `tools/migration-lab/starlight.zig` | Imported implementation (`starlight` mode, including optional subprocess) | `main.zig` → `starlight` | `starlight.zig` |
| `tools/migration-lab/assetfilename.zig` | Imported implementation (`asset-filename` mode) | `main.zig` → `assetfilename` | `assetfilename.zig` |
| `tools/migration-lab/themearchaeology.zig` | Imported implementation (`theme-archaeology` mode) | `main.zig` → `themearchaeology` | `themearchaeology.zig` |
| `tools/migration-lab/themematerialize.zig` | Imported implementation (`theme-materialize` mode) | `main.zig` → `themematerialize` | `themematerialize.zig` |
| `tools/migration-lab/wordpresstheme.zig` | Imported implementation (`wordpress-theme` mode) | `main.zig` → `wordpresstheme` | `wordpresstheme.zig` |
| `tools/migration-lab/linkaudit.zig` | Imported implementation (`link-audit` mode) | `main.zig` → `linkaudit` | `linkaudit.zig` |
| `tools/migration-lab/frontmatterreview.zig` | Imported implementation (`frontmatter-review` mode) | `main.zig` → `frontmatterreview` | `frontmatterreview.zig` |
| `tools/migration-lab/build.zig` | Build configuration | build file → `main.zig` | `build.zig` declares executable and test targets |
| `tools/migration-lab/fixtures/` | Test fixtures | `main.zig` tests → fixtures | Fixtures are stable tracked inputs |
| `tools/migration-lab/README.md` | Documentation | documentation → source | README describes modes and usage |
| `boris` product binary | Potential subprocess target (starlight mode, optional) | `starlight.zig` spawns → `boris` | Boris binary not part of this tool's compilation |
| Root `build.zig` | Possible convenience step (uncertain) | root build → tool build | Uncertain; root `build.zig` not directly inspected |
| Generated output (`migration-report/`, `../out-*`) | Generated output | tool → output dir | Not tracked; consumed by human operator |


***

## Security and trust boundaries

**Input trust model:** The tool reads source files from operator-specified directories. It does not validate that these directories are part of a trusted repository. Content from Instagram Takeout dumps, Obsidian vaults, Notion exports, WordPress WXR files, and theme source trees is **untrusted** and may contain adversarial filenames, malicious frontmatter, embedded HTML, crafted fence sequences, traversal paths, and directive-like comments.

**Markdown fence safety:** The Instagram module uses `longestBacktickRun` to size code fences so caption text cannot escape into live Markdown. This is structurally enforced for Instagram captions. Other modes' Markdown fence safety is uncertain.

**Embedded directives:** `themearchaeology.zig`'s `scanFileContent` explicitly detects directive-like comments (`<!-- agent`, `ignore previous`, etc.) and embedded `[INST]`/`[SYSTEM]` prompts in theme source files, inventorying them as `runtimeassumption` with `.drop` decision and `unsupportedRuntime: true`. These are never followed or replayed. This is the only observed explicit LLM-injection guard in the codebase evidence.

**Path traversal:** `isSafeMediaUri` in `instagram.zig` refuses URIs with traversal patterns. `hasTraversal` in `themearchaeology.zig` refuses traversal CSS import paths. The `main`-level guard is only string equality of `--out` vs named inputs — it does not canonicalize paths. A caller supplying `--root .` and `--out ./migration-report` with `migration-report` inside the scanned tree is not caught unless the module also enforces `refuseOutputInsideSource`.

**Opaque byte copying:** Media files (Instagram, WordPress) are read and written as opaque bytes. No validation of image format, SVG safety, or script content is performed before copying.

**Terminal output:** `std.log.err` and `std.debug.print` output is not sanitized. Filenames containing terminal control sequences could affect operator displays.

**Network exfiltration:** Absent. No network calls are present in `main.zig` or in the modules read. The `starlight` mode optionally spawns a local Boris binary; it does not make network requests.

**Output overwrite:** Existing files in `--out` are overwritten without a staging step. No atomic rename is used. If `run` fails mid-write, the output directory may contain a mix of new and old files.

**Resource exhaustion:** The tool reads entire files into memory (`readFileAlloc`). Very large source files (e.g., a large WXR export or a large Instagram dump) will consume proportional memory. No size cap is applied in `main.zig`; `themearchaeology.zig`'s `scanFileContent` caps text scanning at 512 KB for line-scan purposes, but full file bytes are still read for other operations.

***

## Evidence limitations

- **Root `build.zig`** was not directly inspected. Whether it exposes a convenience step for `boris-migration-lab`, and what that step is named, is uncertain.
- **`tools/migration-lab/build.zig`** was not directly inspected beyond what appears in the INDEX (1,238 bytes, tracked). Exact build declarations and step names are inferred from usage comments in `main.zig`.
- **`tools/migration-lab/README.md`** was not directly read. Usage text embedded in `main.zig` (`printUsage`) is used as the primary CLI reference.
- **`AGENTS.md`**, **`docs/STATUS.md`**, and root changelog entries were not directly inspected.
- **`tools/source-rag/`** files (separate tool) were not inspected; no claim is made about that tool.
- **Exit code assertions** are absent from tests — exit code values are documented in comments only.
- **Cross-platform behavior** (path separator, filesystem enumeration order) is not tested; all byte-comparison tests run on a single platform.
- **Instagram module allocation leak**: the comment "its in-module tests currently leak under the testing allocator" is taken at face value; the nature and scope of the leak is unknown.
- **Notion, Obsidian, Filed, Linkaudit integration tests**: visible via `refAllDecls` inclusion in the test block, but those modules' tests were not fully traced in this review — coverage quality is uncertain beyond what module-level tests declare.
- **Stale output behavior** is inferred from the absence of cleanup calls; not tested.
- **Schema stability**: format identifiers are present for several outputs, but no schema migration, version negotiation, or compatibility contract is observed. Format stability claims are unsupported by the evidence.
- **`--out` containment guard**: the `refuseOutputInsideSource` function is seen exported from `wordpresstheme.zig` and called in `starlight.run`; whether every mode calls it is uncertain.

***

## Final source assessment

`tools/migration-lab/main.zig` is a clean, well-factored CLI entry point for a multi-mode content migration scaffold tool. Its actual responsibility is narrow: parse and validate arguments, enforce the output–input directory inequality invariant, and dispatch to the correct mode module. It does not implement migration logic itself.

**Strongest supported guarantees:** CLI parsing is comprehensive and directly tested for all 13 modes, including both fused and split flag forms and all documented aliases. The `astro` mode has the strongest end-to-end evidence: two-run byte identity, source immutability, adversarial corpus handling, and link classification are all directly demonstrated. The tool does not contact the network (in `main.zig` or in any module read), does not modify Boris product source, and does not invoke subprocesses except through the explicitly guarded `starlight` mode Boris compile verification.

**Weakest or least-tested boundaries:** The `--out` safety guard is string equality only — path canonicalization, symlink aliasing, and containment are not enforced. Stale output from previous runs is not cleaned. The `instagram` module has a known allocator leak that excludes it from the `main.zig` test block's `refAllDecls`. Most non-astro modes lack two-run byte comparison tests in `main.zig`. Schema stability for most machine-readable outputs is undocumented and untested.

**Separation from Boris product runtime:** Complete and well-enforced by architecture. Nothing in this file or its imports is linked into `boris`. The tool's generated output requires deliberate human review and commit before it enters the Boris product content tree.

**Quality of available evidence:** High for CLI surface, `astro` mode behavior, and the `wordpresstheme` module. Moderate for Starlight, Obsidian, Notion, Instagram, and asset-filename modes. Low for stale-output behavior, cross-platform reproducibility, and allocation failure paths.

**Most important unresolved question:** Whether every mode's `run` function calls `refuseOutputInsideSource` (or an equivalent containment check) rather than relying solely on `main`'s string-equality guard — and therefore whether the output-safety invariant is uniformly enforced across all 13 modes.
