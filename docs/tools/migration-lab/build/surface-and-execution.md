---
title: "`tools/migration-lab/build.zig` surface and execution"
id: docs/tools/migration-lab/build/surface-and-execution
parent: docs/tools/migration-lab/build
status: draft
tags: [boris, zig, tools, surface, migration-lab, build]
---

# `tools/migration-lab/build.zig` surface and execution

## CLI surface

The CLI surface is parsed entirely in `main.zig` via `parseOptions`. All flags accept both `--flag=VALUE` (inline `=` form) and `--flag VALUE` (space-separated form).


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `-h`, `--help` | No | false | presence | Print usage text and exit 0 | — |
| `-q`, `--quiet` | No | false | presence | Suppress progress lines to stderr | — |
| `--mode=MODE` | No | `astro` | `astro`, `wordpress`/`wp`/`wxr`, `wordpress-theme`/`wp-theme`/`kubrick-theme`, `instagram`/`ig`/`takeout`, `obsidian`/`obs`/`vault`, `notion`/`md-csv`/`notion-export`, `filed`/`filed-fyi`, `starlight`/`sl`/`evcc`, `asset-filename`/`assets`/`asset-compat`/`filename-compat`, `theme-archaeology`/`theme`/`theme-arch`/`theme-inventory`, `theme-materialize`/`materialize`/`theme-materialise`, `link-audit`/`links`/`output-audit`, `frontmatter-review`/`fm-review`/`fmreview` | Selects active mode; some input flags imply a mode | Exit 2, `invalid flag value`, usage printed |
| `--out=DIR` | No | `migration-report` | Any directory path | Output directory (created if missing) | Exit 2 if `--out` equals any input root |
| `--root=DIR` | No | `.` | Any directory path | Astro/Starlight project root, theme scan root, asset-filename content tree, or link-audit HTML tree | Exit 2 if equals `--out` for applicable modes |
| `--wxr=FILE` | Required for `wordpress` | — | File path | WordPress WXR XML export; implies `--mode=wordpress` | Exit 2 with usage if absent in wordpress mode |
| `--media=DIR` | No | — | Directory path | Local WordPress media mirror; no network | Exit 2 if equals `--out` |
| `--dump=DIR` | Required for `instagram` | — | Directory path | Unpacked Instagram data-download root; implies `--mode=instagram` | Exit 2 with usage if absent |
| `--vault=DIR` | Required for `obsidian` | — | Directory path | Obsidian vault root; implies `--mode=obsidian` | Exit 2 with usage if absent |
| `--export=DIR` | Required for `notion` | — | Directory path | Unpacked Notion Markdown/CSV export root; implies `--mode=notion` | Exit 2 with usage if absent |
| `--filed-root=DIR` | Required for `filed` | — | Directory path | Filed.fyi Astro source root; implies `--mode=filed` | Exit 2 with usage if absent |
| `--ledger=FILE` | Required for `theme-materialize` | — | File path | `adaptationledger.json` from `theme-archaeology` | Exit 2 with usage if absent; exit 2 if equals `--out` or `--root` |
| `--locale=LANG` | No | `en` | `en` only | Starlight discovery key; only English locale supported | Undocumented — uncertain if non-`en` triggers structured error or silent misbehavior |
| `--max-pages=N` | No | `40` | Positive integer | Starlight page-selection cap | Exit 2 on non-integer (`InvalidValue`) |
| `--boris=PATH` | No | auto-detected | File path | Optional Boris binary for Starlight compile verification | Skipped gracefully if binary not found |
| `--content=DIR` | Required for `frontmatter-review` | — | Directory path | Content tree root for frontmatter key audit; implies `--mode=frontmatter-review` | Exit 2 with usage if absent |
| Unknown flag | — | — | — | Exit 2 with "unknown argument", usage printed | — |
| Missing value after flag | — | — | — | Exit 2 with "missing value for flag", usage printed | — |

**Exit codes:** `0` = success, `2` = usage/CLI error, `3` = I/O or runtime error. These are defined as the `ExitCode` enum in `main.zig` and directly demonstrated by tests (`parseOptions unknown flag` → `error.UnknownFlag` → exit 2; `parseOptions invalid mode` → `error.InvalidValue` → exit 2).

**Help output:** Produced by `printUsage()`, printed to stderr via `std.debug.print`. Includes per-mode documentation blocks with alias lists, required inputs, output descriptions, and safety notes. Coverage is extensive but exact formatting is not regression-tested.

***

## Inputs and discovery model

Each mode targets a different input root. All modes share the `--out ≠ input` safety check at the `main.zig` dispatch layer.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Astro `src/content/` Markdown | Recursive walk under `src/content/` then `content/`; `.md`/`.mdx` only | Yes (if directory exists) | `.git`, `node_modules`, `.astro`, `dist`, `.vercel`, `.netlify`, `.output`, `zig-out`, `.zig-cache`, `zig-cache`; `config.ts/mjs/js` files; files matching skip-filename list (`.DS_Store`, `Thumbs.db`) | `archaeology.zig` `skipdirnames` const, `skipfilenames` const; directly tested |
| Astro `src/pages/`, `src/layouts/`, `src/components/`, `public/`, `src/assets/` | Pattern-based path classification | Yes | Same skip-dir list | `archaeology.zig` `classifyPath` |
| Astro `src/content/config.ts` / `content/config.ts` | Classified as `config`, not `contentpage` | Yes | — | `isConfig` function in `archaeology.zig` |
| WordPress WXR XML file | File path from `--wxr` | Required | — | `wordpress.zig`; CLI enforcement |
| WordPress media tree | Recursive walk from `--media` | Optional | Traversal, absolute, symlink paths rejected at copy time | `wordpress.zig`; fixture test `fixturesmedia-wxr` |
| Instagram data-download root | Structured walk under `your_instagram_activity/content/` or top-level `content/` | Required (`--dump`) | Media URIs with `..`, absolute, or Windows separators rejected | `instagram.zig`; hostile fixture |
| Obsidian vault root | Recursive walk; all `.md` files | Required (`--vault`) | `.obsidian/`, `node_modules/`, templates | `obsidian.zig` |
| Notion Markdown/CSV export root | Recursive walk | Required (`--export`) | — | `notion.zig` |
| Filed.fyi Astro source root | Bounded: exactly one changelog, three releases | Required (`--filed-root`) | Unsupported MDX retained as-is | `filed.zig` |
| Starlight root, locale dir | `src/content/docs/<locale>/` or root-locale `src/content/docs/` | Required (`--root`) | Underscore partials, `--max-pages` cap, locale siblings when `skiplocalesiblings` | `starlight.zig` |
| Asset-filename content tree | Recursive walk for `*.md` and `stem.assets/` sibling directories | Required (`--root`) | Traversal destinations, symlinks (detected), same-case-collision destinations | `assetfilename.zig` |
| Theme archaeology root | Recursive walk; all text-scannable extensions | Required (`--root`) | `.git`, `node_modules`, `dist`, `zig-out`, `.zig-cache`, `migration-report` | `themearchaeology.zig` `isSkippedDir` |
| Theme materialize | `--root` (read-only source) + `--ledger` (`adaptationledger.json`) | Both required | No JS/MDX/PHP execution; no remote fetch | `themematerialize.zig` |
| WordPress theme root | Recursive walk of PHP/CSS/asset files | Required (`--root`) | — | `wordpresstheme.zig` |
| Link audit HTML tree | Recursive walk of generated HTML | Required (`--root`) | External, mailto, tel, data, hash-only links excluded from audit | `linkaudit.zig` |
| Frontmatter review content tree | Recursive walk of `.md` files | Required (`--content`) | — | `frontmatterreview.zig` |

**Symlink policy:** Symlinks are detected (evidenced by `FileRec.issymlink` in `wordpresstheme.zig` and `themearchaeology.zig`) and skipped in content scans; SHA-256 is not computed for symlinked files. Media traversal rejection is enforced in Instagram and WordPress modes for unsafe URIs. Symlink-safety across all modes is not uniformly demonstrated.

**Path normalization:** `archaeology.zig` provides `normalizeRelPath` (converts `.\` prefix to POSIX `/`, null-byte replacement) and `normalizeRelPathAlloc`. Directly tested. Other modules' normalization behavior is uncertain without deeper inspection.

***

## Output artifact model

Outputs vary by mode. All modes write only under `--out`.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `report.json` | JSON, mode-specific schema | Lab-owned | Stable field order per mode (documented) | Human/LLM review | Schema versioned (astro/obsidian/notion/filed/starlight: v1; wordpress: v3); bump on field-meaning change |
| `REPORT.md` | Markdown (human-readable twin) | Lab-owned | Same sections as JSON | Human author | Not schema-versioned; layout may change |
| `content/*.md` | Boris-ready Markdown | Lab-owned | Deterministic (sort order, entity-id derivation) | Boris product compiler (author step) | Not pinned to stable format |
| `content/stem.assets/` | Byte-copied media files | Lab-owned | Deterministic within page | Boris product compiler | Content-identical to source |
| `mediamanifest.json` | JSON | Lab-owned | Stable field order | Migration review | Not independently versioned |
| `routemap.json` | JSON, `boris-starlight-route-map` schema v1 | Lab-owned | Entity-id sorted | Author/compiler | Schema v1 |
| `selectionmanifest.json` | JSON | Lab-owned | Lexicographic | Author review | Not independently versioned |
| `unsupportedmanifest.json` | JSON, `boris-starlight-unsupported` schema v1 | Lab-owned | Source-path sorted | Author review | Schema v1 |
| `assetsmanifest.json` | JSON | Lab-owned | Source-path sorted | Author review | Not independently versioned |
| `navflatten.json` | JSON | Lab-owned | Stable | Author review | Not independently versioned |
| `provenancemanifest.json` | JSON | Lab-owned | Source-path sorted | Author review | Not independently versioned |
| `linkreview.json` | JSON | Lab-owned | Source-path sorted | Author review | Not independently versioned |
| `headingfragments.json` | JSON | Lab-owned | Source-path sorted | Author review | Not independently versioned |
| `boundarymanifest.json` | JSON | Lab-owned | Class/sourcepath/detail sorted (directly tested) | Author review | Not independently versioned |
| `compilereport.json` | JSON | Lab-owned | — | Author review | Not independently versioned |
| `adaptationledger.json` | JSON, `boris-theme-archaeology-lab` schema v1 | Lab-owned | Sourcepath/category/decision/reason/evidence sorted (directly tested) | `theme-materialize` mode, human review | Schema v1 |
| `materialize-manifest.json` | JSON | Lab-owned | — | Author review | Not independently versioned |
| `MATERIALIZE-REPORT.md` | Markdown | Lab-owned | — | Human | Not schema-versioned |
| `PROVENANCE.md` | Markdown | Lab-owned | — | Human | Not schema-versioned |
| `BOUNDARY.md` | Markdown | Lab-owned | — | Human | Determinism directly tested (mini-theme-astro fixture) |
| `frontmatterreview.json` | JSON | Lab-owned | — | Author review | Not independently versioned |
| `FRONTMATTERREVIEW.md` | Markdown | Lab-owned | — | Human | Not schema-versioned |
| `linkaudit.json` | JSON | Lab-owned | — | Author review | Not independently versioned |
| `theme/` (materialized Boris theme draft) | Static HTML/CSS/font/image files | Lab-owned | — | Boris product compiler | Content-identical to preserved source bytes |

**Stale output behavior:** WordPress mode re-runs wipe lab-owned content (`content/`, `report.json`, `REPORT.md`, `mediamanifest.json`) before re-writing; stale assets cannot linger. This is documented as an implemented property. Whether all modes perform equivalent cleanup is uncertain — not all modes are evidenced to `deleteTree` prior outputs.

**Required for minimal useful use:** `report.json` (or mode-specific equivalent) plus any generated `content/*.md` tree. Manifests are optional for basic author use.

***

## Serialization and schema behavior

All machine-readable files are serialized as hand-constructed JSON (not using `std.json` emitter) via arena-allocated buffer appends. Field ordering is determined by emission order in each `emit*Json` function, making it stable across repeated runs on identical inputs.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| Astro `report.json` | `"format": "boris-astro-migration-lab"`, `schemaVersion: 1` | `archaeology.zig` | Stable documented field order | Directly tested: key presence in fixture output |
| WordPress `report.json` | `"format": "boris-wordpress-migration-lab"`, `schemaVersion: 3` | `wordpress.zig` | Stable documented field order | Fixture tests; unit-wxr, mini-wxr, media-wxr |
| Instagram `report.json` | `"format": "boris-instagram-migration-lab"`, `schemaVersion: 1` | `instagram.zig` | Stable documented | Fixture tests |
| Obsidian `report.json` | `"format": "boris-obsidian-migration-lab"`, `schemaVersion: 1` | `obsidian.zig` | Stable documented | Fixture tests |
| Notion `report.json` | `"format": "boris-notion-migration-lab"`, `schemaVersion: 1` | `notion.zig` | Stable documented | Fixture tests |
| Filed `report.json` | `"format": "boris-filed-fyi-migration-lab"`, `schemaVersion: 1` | `filed.zig` | Stable documented | Fixture tests |
| Starlight `routemap.json` | `"format": "boris-starlight-route-map"`, `schemaVersion: 1` | `starlight.zig` | Entity-id sorted | Fixture tests |
| Theme archaeology `adaptationledger.json` | `"format": "boris-theme-archaeology-lab"`, `schemaVersion: 1` | `themearchaeology.zig` | sourcepath/category/decision/reason/evidence sorted | Directly tested: determinism, key presence |
| Theme archaeology `report.json` | same format, `schemaVersion: 1` | `themearchaeology.zig` | Stable | Directly tested |
| Asset-filename `assetfilenamemanifest.json` | `"format": "boris-asset-filename-lab"`, `schemaVersion: 1` | `assetfilename.zig` | Stable | Fixture tests |
| Link audit `linkaudit.json` | `"format": "boris-link-audit-lab"`, `schemaVersion: 1` | `linkaudit.zig` | Stable | Fixture tests (uncertain depth) |
| Frontmatter review `frontmatterreview.json` | `"format": "boris-frontmatter-review"`, `schemaVersion: 1` | `frontmatterreview.zig` | Stable | Fixture tests |

**JSON escaping:** Handled by a shared `appendJson` helper (visible in module sources). Special characters in source paths or content are escaped. Whether the helper covers all Unicode edge cases uniformly is uncertain.

**Newline policy:** JSON files use no trailing newline (uncertain — implementation uses buffer appends without explicit trailing newline addition). Markdown reports use standard `\n` line endings.

**Empty arrays:** Emitted as `[]`. Empty segments produce valid but minimal JSON objects.

**Version disagreement:** No parsing of existing output files occurs at runtime; the tool always re-generates. Version compatibility is therefore a schema-read concern for downstream consumers only.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable file discovery order | `std.mem.sort` on collected paths before processing | Directly demonstrated (Astro: `test astro fixture scan produces stable report sections` compares two runs byte-for-byte; theme-archaeology: `test fixture mini-theme-astro ledger shape and determinism`) | Relies on filesystem enumeration completing before sort; symlinks excluded |
| Stable JSON field order | Deterministic emission order in hand-built JSON functions | Structurally checked (field order fixed in source; byte-comparison tests pass) | Not tested on all output formats independently |
| Source immutability | Opens inputs read-only; no write calls on input paths | Directly demonstrated (`test astro sources are never modified`, `test astro adversarial corpus`, `test astro root-level content discovery determinism source immutability`) | Convention-dependent in modes not covered by explicit immutability tests |
| Stable entity-id derivation | Pure function of path string; no random component | Directly demonstrated (`test astro entity id proposal`, `test astro slug derivation is deterministic`) | Dynamic-route pages produce unstable entity IDs by design |
| Stable boundary manifest ordering | Multi-key sort (class, sourcepath, detail) | Structurally checked in `buildBoundaryItems` | Not byte-compared in separate test |
| No timestamps in outputs | Not observed in emitted JSON | Partial coverage (key-presence tests do not explicitly assert timestamp absence) | Uncertain for all modes |
| No random identifiers | Not observed in emitted JSON | Partial coverage | Uncertain for all modes |
| Stable Starlight route map | Entity-id sort after `std.mem.sort` | Structurally checked | Synthetic trunk pages add to set; insertion order matters before sort |
| Stable asset manifest ordering | Source-path sorted | Structurally checked | Not byte-compared in separate determinism test |

Cross-platform byte identity is **uncertain** — not tested or structurally proven. Path separator handling on Windows is not evidenced.

***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into scan root | `--out ≠ input` check at CLI dispatch for every mode | Yes (in `main.zig` switch) | Partially (parseOptions tests verify flag parsing; collision check verified for astro, wordpress modes in dispatch) | Not a separate CI-level test for every mode |
| Media path traversal (`..`, absolute, Windows sep) | Instagram/WordPress reject media URIs with traversal components before any filesystem access; record as `humanreview` / `rejected` | Yes for Instagram and WordPress | Directly tested: hostile-instagram fixture README documents this; `test wordpress media path traversal` implied by `fixturesmedia-wxr` | Uncertain for other modes handling asset paths |
| Symlink traversal | Symlinks detected in file-walk (`issymlink` field); SHA-256 skipped; excluded from content scans | Yes in theme-archaeology and wordpresstheme | Partially (hostile-asset-filenames fixture includes symlink case) | Uniform enforcement across all thirteen modes uncertain |
| Accidental recursion into own output | `--out ≠ input` check + skip-dir names include `migration-report`, `zig-out`, `.zig-cache` in some modules | Partial (only some modules skip `migration-report` by name) | Not explicitly tested for all modes | If caller names `--out` something not in skip-dir list, recursion risk exists |
| Case-collision on output paths | Asset-filename mode detects and reports collisions; refuses silent overwrite | Yes in `assetfilename.zig` | Directly tested (hostile-asset-filenames fixture) | Behavior in other modes on case-insensitive filesystems uncertain |
| Stale output from previous run | WordPress mode wipes lab-owned files before re-writing | Partially implemented (documented for WordPress; uncertain for all modes) | Uncertain | Partial stale output possible in some modes |
| Output-root creation failure | `createDirPath` used; errors propagated as `IoFailure` / exit 3 | Yes (implementation) | Not explicitly tested with permission failures | No test for unwritable `--out` |
| Very large files | No explicit size cap evidenced | Not enforced | Not tested | Potential memory exhaustion on oversized inputs |
| Maliciously chosen filenames (fence injection) | Instagram caption bytes placed inside a fence sized to outrank the longest backtick run | Yes (documented and implemented in instagram.zig) | Partially (hostile-instagram fixture) | Other modes' fence safety uncertain |
| Path-traversal in Markdown `..` destinations | `hasTraversal` function in `themearchaeology.zig`; asset-filename mode enforces at rewrite | Yes in theme-archaeology, asset-filename | Directly tested (hostile-theme-astro, hostile-asset-filenames) | Traversal in Markdown image refs in other modes uncertain |

Best-effort replacement is not atomic. No staging/rename pattern is evidenced.

***

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `ExitCode` | `enum(u8)` | Typed exit codes: `success=0`, `usage=2`, `io_error=3` | — | `.int()` returns raw `u8` | Process-scoped |
| `Mode` | `enum` | Thirteen mode variants | — | Used by `Options`, `main` dispatch | Process-scoped |
| `Mode.parse(s)` | `fn` | Map string (including aliases) to `?Mode` | `const []u8` | `?Mode` (null = unknown) | — |
| `Options` | `struct` | Parsed CLI options with defaults | — | Holds all flag values | Arena-allocated or stack |
| `ParseError` | `error` | CLI parse errors: `UnknownFlag`, `MissingValue`, `InvalidValue` | — | Used by `parseOptions` return type | — |
| `parseOptions(args)` | `fn` | Parse argv slice into `Options` | `[]const []const u8` | `ParseError!Options` | Borrows input slices |
| `printUsage()` | `fn` | Emit usage text to stderr | — | Side effect: `std.debug.print` | — |
| `main` | `pub fn` | Process entry point | `std.process.Init` | `u8` exit code | Process-scoped |

**`main` flow:**

1. Initialize arena allocator and GPA from `std.process.Init`.
2. Read process args via `init.minimal.args.toSlice`; copy into `ArrayList([]const u8)`.
3. Call `parseOptions`; on error, print error message + usage, return exit 2.
4. If `--help`, print usage, return exit 0.
5. Dispatch on `opts.mode`:
    - For each mode: validate required inputs, check `--out ≠ input`, call `mode.run(io, gpa, opts)`.
    - On `run` error: print `"migration-lab <mode> failed: <errorName>"`, return exit 3.
6. Return exit 0.

**Cleanup order:** Arena allocator freed on return via `defer arena.deinit`. GPA cleanup depends on `std.process.Init` lifecycle. No explicit file handle cleanup in `main` beyond what individual mode `run` functions manage with `defer`.

***

## Ownership and lifetime model

- **Process allocator (GPA):** Owned by `std.process.Init`; used for long-lived allocations where arena cannot be used (e.g., per-`run` arenas initialized from GPA).
- **Arena allocator:** Initialized per `main` call (`std.heap.ArenaAllocator.init(gpa)`); `defer arena.deinit()` on return. All per-run allocations in mode modules that accept `a: std.mem.Allocator` use this arena.
- **Argument slices:** Read from `init.minimal.args`; copied into `ArrayList([]const u8)`; individual slice pointers borrowed from the args buffer (lifetime: process).
- **Options struct:** Stack-allocated in `main`; field string pointers borrow from argv slices.
- **Discovered path strings:** Arena-allocated within mode `run` calls; freed on arena deinit.
- **File body buffers:** Arena-allocated (`readFileAlloc` pattern); freed on arena deinit.
- **Output write buffers:** Arena-allocated (`ArrayListu8`, `buf.toOwnedSlice`); freed on arena deinit after write.
- **File handles:** Opened and closed within `run` with `defer file.close(io)` pattern; not held across calls.
- **Temporary output:** No staging directories; files written directly to `--out`.
- **Cleanup on error:** Arena freed via `defer` regardless of error. No partial-output cleanup; previous valid output may be partially overwritten before failure (not atomic).

Leak freedom is **not claimed** — `instagram.zig` tests explicitly note in-module tests "currently leak under the testing allocator" (noted in `main.zig` test aggregation comment).

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Unknown CLI flag | `parseOptions` | `"unknown argument try --help"` + usage to stderr | Exit 2 | None (before mode dispatch) |
| Missing value for flag | `parseOptions` | `"missing value for flag try --help"` + usage | Exit 2 | None |
| Invalid flag value (bad mode, non-integer max-pages) | `parseOptions` | `"invalid flag value try --help"` + usage | Exit 2 | None |
| `--out` equals input path | `main` mode dispatch | Mode-specific message (e.g., `"--out must differ from --root"`) | Exit 2 | None |
| Required mode input absent (no `--wxr`, `--dump`, etc.) | `main` mode dispatch | Mode-specific message + usage | Exit 2 | None |
| I/O failure in mode `run` | mode `run` propagated to `main` | `"migration-lab <mode> failed: <errorName>"` to stderr | Exit 3 | Yes — partial output possible |
| Source not found (`SourceNotFound`) | mode `run` | Same as I/O failure | Exit 3 | Minimal — depends on write ordering |
| Output creation failure | `createDirPath` in mode `run` | Propagated as `IoFailure` | Exit 3 | None if failure before first write |
| Allocation failure | Any `try` allocation | Propagated; `std.log.err` in some paths | Exit 2 or 3 depending on location | Possible partial output |
| Serialization failure | Buffer appends; unlikely but propagated | Propagated as mode failure | Exit 3 | Possible partial output |
| Subprocess failure (Starlight compile) | `tryCompileWithBoris` | Recorded in `compilereport.json` as `"failed"` with stderr excerpt; not fatal | Exit 0 (skipped/failed is a report field) | None — subprocess failure is non-fatal |
| Non-`en` locale (Starlight) | `starlight.run` | `error.LocaleNotSupported` → exit 3 | Exit 3 | None if caught before output |
| Invalid `--max-pages` range | `starlight.run` | `error.InvalidMaxPages` → exit 3 | Exit 3 | None if caught before output |

All user-visible error messages are plain stderr text via `std.log.err` or `std.debug.print`. There are no structured diagnostic objects emitted to stdout.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Build target root (entry point) | `build.zig` → `main.zig` | `main.zig` is authoritative for CLI surface and mode dispatch |
| `tools/migration-lab/archaeology.zig` | Imported implementation (Astro mode) | `main.zig` → `archaeology.zig` | `archaeology.zig` is authoritative for Astro scan logic |
| `tools/migration-lab/wordpress.zig` | Imported implementation (WordPress mode) | `main.zig` → `wordpress.zig` | `wordpress.zig` is authoritative |
| `tools/migration-lab/instagram.zig` | Imported implementation (Instagram mode) | `main.zig` → `instagram.zig` | `instagram.zig` is authoritative |
| `tools/migration-lab/obsidian.zig` | Imported implementation (Obsidian mode) | `main.zig` → `obsidian.zig` | `obsidian.zig` is authoritative |
| `tools/migration-lab/notion.zig` | Imported implementation (Notion mode) | `main.zig` → `notion.zig` | `notion.zig` is authoritative |
| `tools/migration-lab/filed.zig` | Imported implementation (Filed.fyi mode) | `main.zig` → `filed.zig` | `filed.zig` is authoritative |
| `tools/migration-lab/starlight.zig` | Imported implementation (Starlight mode) | `main.zig` → `starlight.zig` | `starlight.zig` is authoritative |
| `tools/migration-lab/assetfilename.zig` | Imported implementation (asset-filename mode) | `main.zig` → `assetfilename.zig` | `assetfilename.zig` is authoritative |
| `tools/migration-lab/themearchaeology.zig` | Imported implementation (theme-archaeology mode) | `main.zig` → `themearchaeology.zig` | `themearchaeology.zig` is authoritative |
| `tools/migration-lab/themematerialize.zig` | Imported implementation (theme-materialize mode) | `main.zig` → `themematerialize.zig` | `themematerialize.zig` is authoritative |
| `tools/migration-lab/wordpresstheme.zig` | Imported implementation (wordpress-theme mode) | `main.zig` → `wordpresstheme.zig` | `wordpresstheme.zig` is authoritative |
| `tools/migration-lab/linkaudit.zig` | Imported implementation (link-audit mode) | `main.zig` → `linkaudit.zig` | `linkaudit.zig` is authoritative |
| `tools/migration-lab/frontmatterreview.zig` | Imported implementation (frontmatter-review mode) | `main.zig` → `frontmatterreview.zig` | `frontmatterreview.zig` is authoritative |
| `tools/migration-lab/fixtures/` | Test fixture input trees | `main.zig` tests → fixtures | Fixtures are authoritative test inputs |
| `tools/migration-lab/README.md` | Documentation | Documents `build.zig` invocations | README describes; `build.zig` implements |
| Root `build.zig` | Build isolation — this tool is NOT included | Separate | Root `build.zig` is authoritative for product build |
| `docs/MIGRATION.md` | Companion author guide | Consumes migration-lab outputs | `MIGRATION.md` is authoritative for author workflow |
| `docs/contracts/frontmatter.md` | Boris closed frontmatter grammar | Referenced by lab for hazard detection | `frontmatter.md` is authoritative |
| `docs/contracts/content-local-assets.md` | Boris asset path contract | Referenced by lab for asset safety rules | `content-local-assets.md` is authoritative |
| Boris product `boris` binary | Optional subprocess target (Starlight compile verification) | `starlight.zig` → spawns `boris` | Boris binary is independent runtime |
| Generated report directories | Lab-owned output | `run` → filesystem | Disposable; not tracked |


***

## Security and trust boundaries

**Input trust model:** All inputs (`--root`, `--wxr`, `--dump`, `--vault`, `--export`, `--filed-root`, `--content`, `--ledger`) are treated as untrusted foreign content. The tool is designed to run against adversarial corpora (hostile fixtures exist for Astro, WordPress, Instagram, Starlight, and asset-filename modes).

**Path traversal:** `..` components in media URIs are detected and rejected before filesystem access in Instagram and WordPress modes (directly tested). Theme-archaeology and asset-filename modes check `hasTraversal` for Markdown link destinations. However, traversal checking is not uniformly centralized — each mode's policy must be inspected independently.

**Arbitrary source-file bytes:** Source file bytes are read into arena-allocated buffers and processed as text. No execution of source content occurs. MDX/JSX is stripped (not followed); PHP is never executed; JavaScript is never evaluated; remote CSS is never fetched; embedded directives are stripped, not followed. These are documented invariants, partially demonstrated by hostile fixtures.

**Markdown fence safety:** Instagram captions are enclosed in fences sized to outrank the longest backtick run in the caption, so caption text cannot escape into live Markdown syntax. This is a directly implemented and documented safety property. Whether all other modes apply equivalent fence sizing is uncertain — other modes produce Markdown body content from foreign bytes without explicit fence-escape evidence.

**Embedded frontmatter in packed documents:** Lab-generated `content/*.md` files include Boris closed frontmatter. The lab never invents frontmatter fields outside the closed grammar (`id`, `title`, `parent`, `status`, `tags`). Provenance information is written as HTML comments (`<!-- boris-migration-provenance ... -->`), not as frontmatter fields.

**Output overwrite:** The lab overwrites previous output for WordPress mode (wipes lab-owned files before re-run). Other modes' overwrite behavior is uncertain. No atomic rename is used; partial overwrites on failure are possible.

**Resource exhaustion:** No file-size caps are evidenced. Very large WXR files, large Notion exports, or high-cardinality Obsidian vaults could exhaust arena memory. No explicit bounds are tested.

**Maliciously chosen filenames:** Hostile-asset-filenames fixture exercises spaces, Unicode, percent-encoded names, case collisions, and traversal destinations. The sanitizer's output is constrained to Boris ASCII path grammar. Terminal injection via unusual filenames in progress output is not explicitly mitigated.

**Network exfiltration:** Absent. No HTTP client is imported. The Starlight compile-verification subprocess spawns a local `boris` binary with filesystem arguments only. This is a documented invariant partially supported by the absence of network imports in the standard library usage.

**Trusted repository configuration:** The `--boris` path, `--root`, and `--locale` values are caller-supplied and trusted as configuration. Passing a malicious `--boris` path could invoke arbitrary binaries; this is a caller-discipline assumption, not a mechanically enforced boundary.

***

## Evidence limitations

- **`tools/migration-lab/build.zig` source was not directly read** — the file is listed in the catalog at 1,238 bytes and the README documents its invocation model, but the exact `addExecutable`, `addRunArtifact`, and `addTest` declarations were not inspected. All claims about build structure are inferred from README invocation commands, catalog size, and standard Zig 0.16 build idiom.
- **`tools/migration-lab/build.zig.zon`** was not inspected. Whether external package dependencies are declared is unknown (assessed as absent based on standard-library-only evidence in module sources).
- **Root `build.zig`** was not inspected for any `--build-file` convenience step or reference to `tools/migration-lab/`.
- **`AGENTS.md`**, **`docs/STATUS.md`**, root changelog entries, and `docs/MIGRATION.md` were not directly inspected.
- **Instagram in-module tests** are excluded from the aggregated test binary due to a known arena leak under the testing allocator; this gap is noted in `main.zig` but the extent of Instagram coverage is uncertain.
- **Byte-identical repeated-run tests for WordPress, Instagram, Obsidian, Notion, Filed, Starlight, asset-filename, link-audit, and frontmatter-review modes** are not evidenced — only Astro and theme-archaeology modes have explicit two-run byte-comparison tests.
- **Cross-platform behavior** (Windows path separators, case-insensitive filesystems, line endings) is not tested or structurally proven.
- **Allocation-failure coverage** is absent across all modes.
- **`--out` containment** is not tested with symlinked output directories, or with `--out` paths that resolve to the same inode as an input root.
- **Subprocess error handling** in Starlight compile verification is tested only by the non-fatal "skipped" path; failure exit codes from `boris` are recorded in `compilereport.json` but not validated by a test that intentionally passes a broken corpus.
- **`tools/migration-lab/CHANGELOG.md`** was not inspected for schema history.

***

## Final source assessment

`tools/migration-lab/build.zig` is a compact standalone build script (~1,238 bytes) whose responsibility is to wire the `boris-migration-lab` executable, its `run` convenience step, and its test binary from `main.zig` and thirteen peer mode modules. It enforces the tool's separation from the Boris product binary through build isolation: root `zig build` never compiles it, and it carries no dependency on the product compiler.

**Strongest supported guarantees:** The tool's separation from the Boris product runtime is structurally enforced by build isolation. Source immutability for Astro mode is directly demonstrated by fixture tests. Deterministic repeated-run output is directly demonstrated for Astro and theme-archaeology modes. The CLI surface (parsing, exit codes, flag aliases, required-input enforcement) is extensively unit-tested.

**Weakest or least-tested boundaries:** Byte-identical determinism for the majority of modes (WordPress, Instagram, Obsidian, Notion, Filed, Starlight, asset-filename, link-audit, frontmatter-review) is not directly tested. Stale-output cleanup for all modes except WordPress is unconfirmed. The `build.zig` source itself was not directly read, making exact build declarations uncertain. Instagram test coverage is incomplete due to an acknowledged allocator leak.

**Separation from Boris product runtime:** Structurally complete. The tool is never linked into `boris`, never imported by the product compiler, and writes only to caller-specified output directories that are explicitly prohibited from being the same as any input root.

**Quality of available evidence:** High for CLI surface, Astro mode, theme-archaeology mode, WordPress mode, and hostile-input handling. Moderate for Starlight mode. Low for the build file's exact declarations, cross-platform behavior, and allocation safety.

**Most important unresolved question:** Does `tools/migration-lab/build.zig` declare any build options or external package dependencies beyond the standard Zig build idiom evidenced by the README? Reading the 1,238-byte file directly
<span style="display:none">[^1_1][^1_2][^1_3][^1_4][^1_5][^1_6][^1_7]</span>

<div align="center">⁂</div>

[^1_1]: INDEX.md

[^1_2]: boris-source-4.md

[^1_3]: boris-source-3.md

[^1_4]: boris-source-2.md

[^1_5]: boris-source-1.md

[^1_6]: boris-docs.md

[^1_7]: boris-content.md
