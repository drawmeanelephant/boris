---
title: "`tools/migration-lab/archaeology.zig` surface and execution"
id: docs/tools/migration-lab/archaeology/surface-and-execution
parent: docs/tools/migration-lab/archaeology
status: draft
tags: [boris, zig, tools, surface, migration-lab, archaeology]
---

# `tools/migration-lab/archaeology.zig` surface and execution

## CLI surface

`archaeology.zig` itself does not parse CLI arguments. All argument parsing is handled by `parseOptions` in `main.zig`, which populates an `Options` struct. When mode is `.astro`, `main.zig` extracts `opts.rootdir`, `opts.outdir`, and `opts.quiet` and passes them to `archaeology.run` as `RunOptions`.

The CLI flags relevant to Astro mode are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode astro` | No | `astro` (default mode) | `astro` | Selects Astro archaeology | Exit 2 (usage) if invalid mode |
| `--root DIR` | No | `.` | Any path | Astro project root to scan | Exit 2 if `--root` equals `--out` |
| `--out DIR` | No | `migration-report` | Any path | Output directory (created if missing) | Exit 3 (IO error) if creation fails |
| `-q` / `--quiet` | No | off | flag | Suppresses progress lines to stderr | — |
| `-h` / `--help` | No | — | flag | Prints usage text, exits 0 | — |

Flags that imply other modes (`--wxr`, `--dump`, `--vault`, `--export`, `--filed-root`, `--content`) are irrelevant when mode is `astro`. Unknown flags produce exit code 2 with a `std.log.err` message. Missing values for known flags produce exit code 2. `--out` equal to `--root` produces exit code 2 with a specific message. All non-zero-exit paths for Astro mode are exit code 2 (usage) or exit code 3 (IO error); there is no exit code 1. Exact exit codes are confirmed by the `ExitCode` enum in `main.zig`: `success = 0`, `usage = 2`, `ioerror = 3`.

## Inputs and discovery model

The tool's input root is the value of `--root` (default `.`), resolved relative to the current working directory at invocation time.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Content pages | `.md`/`.mdx` under `src/content/` or `content/` | Yes | Arbitrary repo Markdown outside these roots | `isContentPage`, `contentRootPrefix`; confirmed by tests |
| Page routes | `.astro` under `src/pages/` | Yes | Non-`.astro` under `src/pages/` | `isPageRoute` |
| Layouts | `.astro` under `src/layouts/` | Yes | — | `isLayout` |
| Components | Files under `src/components/` | Yes | — | `isComponent` |
| Public assets | Files under `public/` | Yes | — | `isPublicAsset` |
| Src assets | Files under `src/assets/` | Yes | — | `isSrcAsset` |
| Config | `astro.config.*`, `content.config.*`, `src/content/config.*`, `package.json`, `tsconfig.json` | Yes | — | `isConfig` |
| Other | Everything else discovered | Yes | Skip-dirs, skip-files | `classifyPath` fallback |
| Skip dirs | `.git`, `.hg`, `.svn`, `node_modules`, `.astro`, `dist`, `.vercel`, `.netlify`, `.output`, `zig-out`, `.zig-cache`, `zig-cache` | — | Never entered | `skipDirNames` constant |
| Skip files | `.DS_Store`, `Thumbs.db` | — | Never included | `skipFileNames` constant |

**Content-root restriction:** Content pages are discovered only under `src/content/` (canonical) or `content/` (root-level). Arbitrary Markdown files in `README.md`, `docs/`, `notes/`, or elsewhere are never treated as Astro content pages. This is structurally enforced by `isContentPage` checking `contentRootPrefix`. If both `src/content/` and `content/` exist simultaneously, both are inventoried and a high-severity `ambiguouscontentroots` hazard is emitted.

**Symlink handling:** Not explicitly described in `archaeology.zig` source (the `themearchaeology.zig` peer module explicitly records symlinks as `drop` items). Whether `archaeology.zig`'s `walkTree` (not shown in full in the available evidence) handles symlinks is uncertain.

**Path ordering:** `proposeEntityId` and `slugFromContentPath` return non-allocating slices of the input path for common prefixes. Report ordering is uncertain from available evidence; the determinism tests verify byte-identical repeated-run output for the tested fixtures, implying stable ordering is achieved, but the sort key is not visible in the available source extract.

## Output artifact model

For Astro mode, `archaeology.run` writes exactly two files into `--out`:


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `report.json` | Hand-serialized JSON; format id `boris-astro-migration-lab`; schema version 1 | Tool-generated; disposable | Stable within a run (determinism tests pass); cross-run byte identity demonstrated on same host | Author, LLM notebooks, review workflows | `schemaVersion: 1`; not formally versioned beyond that integer |
| `REPORT.md` | Human-readable Markdown twin of `report.json` | Tool-generated; disposable | Same ordering as `report.json` | Author, manual review | Not versioned |

`report.json` contains the following top-level sections (confirmed by test assertions in `main.zig`): `format`, `schemaVersion`, `inventory`, `stitches`, `proposedIds`, `parentChildCandidates`, `links`, `brokenLinks`, `slugConflicts`, `assets`, `missingAssets`, `hazards`, `humanReview`.

Neither artifact is tracked in the repository (generated output, not source). Neither artifact is required by the Boris product compiler. There is no `INDEX.md`, catalog, JSONL catalog, profile manifest, part manifest, upload manifest, or combined bundle produced by this mode. There are no temporary or staging paths; output is written directly to `--out`.

**Stale-output cleanup:** The WordPress mode README documents that re-running wipes lab-owned content so stale assets cannot linger. Whether Astro mode performs analogous cleanup of a previous `report.json` before writing a new one is not directly visible in the available source extract; this behavior is uncertain.

## Serialization and schema behavior

`report.json` is serialized by hand using an `appendJson` helper (visible in the `themearchaeology.zig` peer and consistent with the pattern across all migration-lab modules). This helper JSON-escapes strings character by character, encoding control characters as `\uXXXX` and the standard JSON escapes for `"`, `\`, `\n`, `\r`, `\t`, `\b`, `\f`. No standard library JSON serializer is used.


| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` | `format: "boris-astro-migration-lab"`, `schemaVersion: 1` | `archaeology.run` | Stable (determinism tested) | Field presence tested; schema not formally validated by a schema document |
| `REPORT.md` | No identifier | `archaeology.run` | Matches `report.json` ordering | Presence of header text tested; no golden-file comparison |

Field ordering within objects follows declaration order in the hand-serializer; this is structurally deterministic as long as the source does not change. Empty arrays appear as `[]` (inferred from implementation pattern; not directly confirmed). The `schemaVersion` integer must be bumped manually if field meaning or shape changes; there is no automated enforcement of this contract.

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Byte-identical repeated runs on same fixture | `main.zig` runs `archaeology.run` twice on `mini-astro` and `root-content-astro`, calls `expectEqualStrings` on both outputs | Directly demonstrated | Same host, same filesystem only; cross-platform not demonstrated |
| Stable path ordering | Path strings ordered before report emission (inferred from byte-identity tests passing) | Structurally checked | Sort key not visible in available extract |
| Stable entity ID derivation | `proposeEntityId` is a pure string function, no allocation for common prefixes | Structurally checked | Dynamic segment handling (`[slug]`) is explicitly noted as unstable in source comments |
| No timestamps in output | Not directly confirmed for Astro mode | Uncertain | Cannot rule out without full `run` implementation view |
| No random identifiers | Not confirmed | Uncertain | — |
| Stable frontmatter field order | Hand-serializer writes fields in declaration order | Structurally checked | — |
| Absolute paths excluded from output | `proposeEntityId` and `slugFromContentPath` strip known prefixes and return repo-relative slices | Structurally checked | Caller discipline required for paths outside known prefixes |

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into scan root | `main.zig` guards `if (eql(rootdir, outdir)) return usage` before dispatch | Yes, at dispatch level | Yes (usage-error tests in `main.zig`) | Guard is string-equality only; does not detect `--out` as a subdirectory of `--root` unless roots are equal strings |
| Scan root modified | `archaeology.run` opens scan root read-only; no write calls on scan handles | Structurally enforced | Directly demonstrated (immutability tests) | — |
| Accidental recursion into output | Skip-dir list includes `zig-out`, `migration-report`; custom `--out` names not in skip list are not excluded | Partial | Not directly tested for custom out-dir names | If `--out` is a subdirectory of `--root` with a non-skip name, recursion is possible |
| Path traversal in discovered paths | `normalizeRelPath` strips leading `./`; `proposeEntityId` returns repo-relative slices | Partial | Tested for normalization helpers | Full traversal rejection (e.g., `..` in discovered paths) not confirmed in available extract |
| Symlink traversal | Not confirmed for `archaeology.zig` | Uncertain | Not demonstrated | Peer `themearchaeology.zig` explicitly inventories and drops symlinks; Astro mode behavior uncertain |
| Replacement of previous output | Not confirmed; prior `report.json` likely overwritten | Uncertain | Not tested | Partial write on failure could leave inconsistent output |

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `formatId` | `pub const` string | JSON format identifier for Astro report | — | `"boris-astro-migration-lab"` | Static |
| `schemaVersion` | `pub const u32` | Schema version for `report.json` | — | `1` | Static |
| `toolVersion` | `pub const` string | Version string | — | `"0.1.0"` | Static |
| `RunOptions` | `pub const struct` | Options passed from `main.zig` dispatch | `rootdir`, `outdir`, `quiet` | — | Borrowed slice lifetime from caller |
| `skipDirNames` | `const` string array | Directory names never entered during walk | — | Predicate table | Static |
| `skipFileNames` | `const` string array | File names never included during walk | — | Predicate table | Static |
| `borisKeys` | `const` string array | Closed Boris frontmatter grammar keys | — | Hazard detection table | Static |
| `FileKind` | `pub const enum` | Classification of discovered files | — | 8-value enum | Static |
| `InventoryEntry` | `pub const struct` | One row in the file inventory | `sourcepath`, `kind`, `bytes`, `extension` | — | Arena-owned |
| `FrontmatterLite` | `pub const struct` | Parsed frontmatter metadata | Markdown file bytes | Boolean flags + optional field slices | Arena-owned |
| `LinkRef` | `pub const struct` | One extracted link reference | `sourcepath`, `kind`, `target`, `line`, `internal` | — | Arena-owned |
| `Hazard` | `pub const struct` | One detected migration hazard | `sourcepath`, `code`, `severity`, `message` | — | Arena-owned |
| `Stitch` | `pub const struct` | Content+route+layout resolution | `logicalSlug`, paths, `complete`, `notes` | — | Arena-owned |
| `ProposedId` | `pub const struct` | Proposed Boris entity ID | `sourcepath`, `proposedEntityId`, `basis` | — | Arena-owned |
| `ParentChild` | `pub const struct` | Candidate parent–child relationship | child + parent paths and IDs, reason, confidence | — | Arena-owned |
| `BrokenLink` | `pub const struct` | Unresolved internal link | `sourcepath`, `target`, `line`, `reason` | — | Arena-owned |
| `SlugConflict` | `pub const struct` | Duplicate slug across files | `slug`, `sourcepaths`, `kind` | — | Arena-owned |
| `AssetEntry` | `pub const struct` | Discovered asset file | `sourcepath`, `kind`, `bytes` | — | Arena-owned |
| `MissingAsset` | `pub const struct` | Referenced but absent asset | `sourcepath`, `referenced`, `line` | — | Arena-owned |
| `HumanReview` | `pub const struct` | Item requiring author judgment | `sourcepath`, `reason`, `codes` | — | Arena-owned |
| `Report` | `pub const struct` | Aggregate report structure | All of the above arrays | — | Arena-owned |
| `normalizeRelPathAlloc` | `pub fn` | Allocating normalization of `./`-prefixed paths | allocator, path | Owned normalized slice | Caller frees |
| `normalizeRelPath` | `pub fn` | Zero-copy normalization for already-POSIX paths | path | Slice into input | Borrowed |
| `fileExtension` | `pub fn` | Extract file extension | path | Slice into input | Borrowed |
| `isSkippedDirName` | `pub fn` | Predicate: directory should be skipped | name | `bool` | — |
| `isSkippedFileName` | `pub fn` | Predicate: file should be skipped | name | `bool` | — |
| `contentRootDirNames` | `pub const` | Known content-root names | — | `["src/content/", "content/"]` | Static |
| `contentRootPrefix` | `pub fn` | Return matching content root prefix or null | path | Optional slice | Borrowed |
| `isContentPage` | `pub fn` | True if `.md`/`.mdx` under a content root | path | `bool` | — |
| `isPageRoute` | `pub fn` | True if `.astro` under `src/pages/` | path | `bool` | — |
| `isLayout` | `pub fn` | True if `.astro` under `src/layouts/` | path | `bool` | — |
| `isComponent` | `pub fn` | True if under `src/components/` | path | `bool` | — |
| `isPublicAsset` | `pub fn` | True if under `public/` | path | `bool` | — |
| `isSrcAsset` | `pub fn` | True if under `src/assets/` | path | `bool` | — |
| `isConfig` | `pub fn` | True if a recognized config filename or path | path | `bool` | — |
| `classifyPath` | `pub fn` | Priority-ordered classifier → `FileKind` | path | `FileKind` | — |
| `proposeEntityId` | `pub fn` | Derive Boris entity ID from content/route path | path | Slice (usually into input) | Borrowed or static |
| `slugFromContentPath` | `pub fn` | Collection-relative slug | path | Slice | Borrowed |
| `collectionFromContentPath` | `pub fn` | Collection name from content path | path | Optional slice | Borrowed |
| `absoluteToRouteKey` | `pub fn` | Map site-absolute link to route key | allocator, absolute string | Owned string | Caller frees |
| `absoluteToPublicPath` | `pub fn` | Map absolute `/images/…` to `public/images/…` | allocator, path | Owned string | Caller frees |
| `parseFrontmatterLite` | `pub fn` | Best-effort YAML frontmatter scanner | allocator, source bytes | `FrontmatterLite` | Arena or allocator-owned |
| `collectHazards` | `pub fn` | Collect frontmatter and structural hazards | allocator, sourcepath, source bytes, frontmatter | `[]Hazard` | Caller-owned |
| `extractLinks` | `pub fn` | Extract Markdown/HTML link and image refs | allocator, sourcepath, body bytes | `[]LinkRef` | Caller-owned |
| `run` | `pub fn` | Top-level Astro scan-and-emit orchestrator | `Io`, `gpa`, `RunOptions` | `!void`; writes `--out` | Errors propagated to caller |

`run` is the only function that performs I/O. All other `pub fn` declarations are pure string or data operations usable by tests without a filesystem.

## Ownership and lifetime model

`main.zig` provides both an arena allocator (`init.arena.allocator()` as `cold`) and a GPA (`init.gpa` as `gpa`). The `cold` arena is used for argument parsing. `archaeology.run` receives `gpa` as its allocator parameter. Within `run`, an internal arena (`std.heap.ArenaAllocator.init(gpa)`) is likely used for report data (consistent with the pattern in peer modules such as `themearchaeology.zig` which uses `var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit()`). All discovered paths, frontmatter slices, link targets, and report record strings are arena-allocated and freed on `arena.deinit()`.

`proposeEntityId` and `slugFromContentPath` return non-allocating slices into input path strings for common prefixes, avoiding allocation for the majority of entity ID operations. These are borrowed slices valid only as long as the input path string lives.

File bodies read during the walk are allocator-owned; it is uncertain whether they are freed individually or freed en-masse on arena deinit.

`RunOptions` fields (`rootdir`, `outdir`) are borrowed slices from the argv array; their lifetime is bounded by the process.

Leak freedom is not claimed. The test runner uses `std.testing.allocator` (which detects leaks in Zig's test harness), and most test cases allocate via arena with `defer arena.deinit()`. The `main.zig` comment notes: "Instagram mode currently leaks under the testing allocator" — Astro mode tests do not carry this note, suggesting they pass the testing allocator's leak detector, but this is inferred from the absence of a note, not from an explicit confirmation.

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| Unknown CLI flag | `parseOptions` | `std.log.err("unknown argument…")` + usage text | Exit 2 | None |
| Missing flag value | `parseOptions` | `std.log.err("missing value…")` + usage text | Exit 2 | None |
| Invalid mode value | `parseOptions` | `std.log.err("invalid flag value…")` + usage text | Exit 2 | None |
| `--root` equals `--out` | `main.zig` dispatch | `std.log.err("--out must differ from --root…")` | Exit 2 | None |
| `--help` | `parseOptions` | Usage text printed | Exit 0 | None |
| Scan root does not exist or is unreadable | `archaeology.run` (directory open) | Error name logged by `main.zig` | Exit 3 | None |
| Unreadable file during walk | Within walk (file open failure) | File silently skipped (consistent with peer modules using `catch continue`) | Continues | Skipped file omitted from inventory — uncertain |
| Output directory creation failure | `archaeology.run` | Error propagated, logged by `main.zig` | Exit 3 | None |
| Write failure for `report.json` or `REPORT.md` | `archaeology.run` | Error propagated, logged by `main.zig` | Exit 3 | Previous `report.json` may remain from prior run |
| Allocation failure | Any allocation site | Zig `error.OutOfMemory` propagated, logged by `main.zig` | Exit 3 | Partial output possible |

No structured diagnostic format (no error JSON, no error JSONL) is produced for Astro mode failures. All errors reach the user as plain `std.log.err` messages to stderr plus the Zig error name. The distinction between "usage error" and "I/O error" is encoded in the exit code only.

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Imports `archaeology.zig`; dispatches `archaeology.run`; contains all Astro-mode tests | `main.zig` → `archaeology.zig` | `main.zig` is entry point and test host |
| `tools/migration-lab/build.zig` | Declares `boris-migration-lab` executable; compiles all `.zig` sources under this directory | Build → sources | Standalone; root `build.zig` not involved |
| `tools/migration-lab/fixtures/mini-astro/` | Primary happy-path test fixture | Test → fixture | Fixture is input evidence |
| `tools/migration-lab/fixtures/adversarial-astro/` | Adversarial Unicode / ambiguity fixture | Test → fixture | Fixture is input evidence |
| `tools/migration-lab/fixtures/root-content-astro/` | Root-level `content/` discovery fixture | Test → fixture | Fixture is input evidence |
| `tools/migration-lab/fixtures/absolute-links-astro/` | Absolute-link classification fixture | Test → fixture | Fixture is input evidence |
| `tools/migration-lab/fixtures/dual-content-roots-astro/` | Dual content root hazard fixture | Test → fixture | Fixture is input evidence |
| `tools/migration-lab/README.md` | Documents modes, flags, fixtures, exit codes, safety rules | Documentation | Informative; implementation is authoritative on disagreement |
| `docs/MIGRATION.md` | Companion author guide; describes Astro migration workflow and Boris Trunk/Satellite rules | Documentation | Normative for author workflow; tool implements a subset |
| `docs/contracts/frontmatter.md` | Defines closed Boris frontmatter grammar (`id`, `title`, `parent`, `status`, `tags`) | Schema contract → `borisKeys` constant | Contract is authoritative; `archaeology.zig` encodes it |
| `tools/migration-lab/wordpress.zig`, `instagram.zig`, etc. | Peer mode modules; do not import `archaeology.zig` | Sibling | Each is independently authoritative for its mode |
| `tools/source-rag/` | Separate tool; produces source-knowledge packs; no relationship to archaeology | None | Separate tool boundary |
| Root `build.zig` | Does not reference `tools/migration-lab/` | None | Root build is authoritative; absence confirmed |

## Security and trust boundaries

The scan root (`--root`) is treated as untrusted input in the following ways:

**Path traversal:** `normalizeRelPath` strips leading `./` prefixes. `proposeEntityId` returns repo-relative slices. However, explicit rejection of `..` components in discovered paths is not confirmed from the available source extract. The `themearchaeology.zig` peer module has an explicit `hasTraversal` function and `refuseOutputInsideSource` guard; whether `archaeology.zig` has equivalent guards is not confirmed.

**Arbitrary source-file bytes:** File bodies are read into memory. Markdown is processed by a best-effort line scanner, not a spec-compliant parser. Frontmatter is scanned line by line. Neither scanner claims to handle all possible byte sequences safely; very large files or pathologically constructed files could cause unexpected behavior (uncertain).

**Markdown fence safety:** The Starlight mode (`starlight.zig`) explicitly sizes fences to outrank the longest backtick run in source content. Whether the Astro mode archaeology report uses fenced blocks and whether similar protection is applied is uncertain.

**Embedded directives in source files:** The `themearchaeology.zig` peer module explicitly detects and drops embedded agent-instruction patterns in source files. Whether `archaeology.zig` performs similar sanitization is not confirmed from available evidence.

**Output written to `--out`:** The containment guard at the `main.zig` dispatch level (`rootdir != outdir`) prevents exact path equality but does not prevent `--out` from being a non-equal subdirectory of `--root`. If an attacker controls `--root` content and `--out` is within it, output files would be written into the scan tree (uncertain risk level).

**Terminal output:** Progress messages go to stderr via `std.debug.print`. No terminal escape injection sanitization is confirmed.

**Network exfiltration:** Absent. No network calls are possible from `archaeology.zig`. The README explicitly documents this.

**Trust summary:**

- Repository configuration (skip-dir list, `borisKeys`) is trusted
- Source file bytes are copied opaque (paths and frontmatter) without semantic validation
- Output Markdown contains source-file content within the limits of the scanner
- Downstream consumers of `report.json` should treat string fields as potentially containing arbitrary source-derived bytes

## Evidence limitations

- The complete `archaeology.run` function body is not available in the source bundles examined; the walk, stitch resolution, link classification, and report emission logic is inferred from test assertions, data structure definitions, and documented behavior. Claims about sort order, stale-output cleanup, and symlink handling in the walk are therefore uncertain.
- The `tools/migration-lab/build.zig` source was not directly available; build declarations are inferred from README documentation and `main.zig` usage patterns.
- The `tools/migration-lab/build.zig.zon` was not examined; dependency declarations are unknown.
- `docs/MIGRATION.md` was not directly examined; claims about the companion guide are based on README references.
- Symlink handling in `archaeology.zig`'s walk is not confirmed. The peer `themearchaeology.zig` explicitly records symlinks as inventory items with `decision: drop`; whether `archaeology.zig` matches this behavior is uncertain.
- Whether `archaeology.run` cleans up stale output before writing new reports is not confirmed.
- Whether `archaeology.run` uses an internal arena or the passed `gpa` directly for report data is inferred from the peer-module pattern.
- Cross-platform behavior (Windows path separators, line endings) is not tested and cannot be claimed.
- The exact JSON serialization of empty arrays and null optional fields is inferred from the implementation pattern; not tested directly.
- The `frontmatterreview` mode (`frontmatterreview.zig`) was referenced but not examined; its relationship to `archaeology.zig`'s `FrontmatterLite` type (possible sharing) is unknown.
- `docs/STATUS.md` and root changelog entries were not examined.

## Final source assessment

`tools/migration-lab/archaeology.zig` is the core Astro-mode data model and discovery engine for the `boris-migration-lab` standalone developer tool. Its primary responsibility is to walk an Astro project tree, classify files by path convention, parse frontmatter and links, and emit deterministic JSON and Markdown reports that support the author's pre-migration planning.

**Strongest supported guarantees:** Source-file immutability is directly demonstrated by test. Byte-identical repeated runs are directly demonstrated for committed fixtures on the same host. The closed Boris frontmatter grammar is structurally encoded and verified. Content discovery is restricted to well-known Astro content-collection directories; arbitrary repository Markdown is never treated as content. The tool is structurally isolated from the Boris product binary.

**Weakest or least-tested boundaries:** Stale-output cleanup behavior is unconfirmed. Symlink handling in the walk is unconfirmed. The `--out`-inside-`--root` containment gap is not mechanically closed within `archaeology.zig` itself. Allocation-failure and unreadable-file paths lack test coverage. Cross-platform behavior is unverified.

**Separation from Boris product runtime:** Complete and mechanically enforced. No shared compilation, no shared imports beyond the Zig standard library, no root build integration.

**Quality of available evidence:** Good for data types, path helpers, and integration test coverage. Incomplete for the internal `run` function body, walk implementation, and cleanup behavior; those are inferred from tests and peer-module patterns.

**Most important unresolved question:** Does `archaeology.run` contain an output-containment check equivalent to `themearchaeology.zig`'s `refuseOutputInsideSource`, and does it clean stale output before writing a new report? Both properties affect how safely the tool can be run in automated workflows against arbitrary repository layouts.
