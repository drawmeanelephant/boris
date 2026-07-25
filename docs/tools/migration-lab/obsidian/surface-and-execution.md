---
title: "`tools/migration-lab/obsidian.zig` surface and execution"
id: docs/tools/migration-lab/obsidian/surface-and-execution
parent: docs/tools/migration-lab/obsidian
status: draft
tags: [boris, zig, tools, surface, migration-lab, obsidian]
---

# `tools/migration-lab/obsidian.zig` surface and execution

## CLI surface

The CLI is parsed entirely by `main.zig` (`parseOptions`). `obsidian.zig` receives only a `RunOptions` struct. The obsidian-relevant flags are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--vault &lt;DIR>` or `--vault&lt;DIR>` | Yes (for obsidian mode) | `null` | Any non-empty string | Sets `vaultdir`; implies `--mode obsidian` | Missing: prints usage, exits 2 |
| `--mode obsidian` | No (implied by `--vault`) | `astro` | `obsidian`, `obs`, `vault` | Selects obsidian mode explicitly | Invalid value: exits 2 |
| `--out &lt;DIR>` or `--out&lt;DIR>` | No | `migration-report` | Any non-empty string | Sets `outdir`; must differ from `--vault` | If equal to `--vault`: exits 2 |
| `-q` / `--quiet` | No | `false` | Flag presence | Suppresses progress line to stderr | N/A |
| `-h` / `--help` | No | `false` | Flag presence | Prints full usage text, exits 0 | N/A |
| Unknown flag | — | — | — | — | Prints error + usage hint, exits 2 |
| Missing value after `--vault` | — | — | — | — | `MissingValue` error → exits 2 |

**Exit codes:** `0` = success, `2` = usage error, `3` = I/O error (propagated from `obsidian.run` via `std.log.err` + `return ExitCode.io_error.int()`). Exact exit codes are declared in `main.zig` as `pub const ExitCode = enum(u8) { success = 0, usage = 2, io_error = 3 }`.

No obsidian-specific flags beyond `--vault` and `--out` exist. There is no `--max-pages`, `--locale`, or profile selection for this mode.

## Inputs and discovery model

`obsidian.zig` treats the `vaultdir` as its sole input root. It performs a deterministic recursive walk, skipping known non-content directories.

**Skip directories (hardcoded):** `.git`, `.hg`, `.svn`, `node_modules`, `.astro`, `dist`, `.vercel`, `.netlify`, `.output`, `zig-out`, `.zig-cache`, `zig-cache`. Additionally `.obsidian` is skipped (confirmed by fixture test assertion that `.obsidian` does not appear in report). The exact skip-dir list in `obsidian.zig` may differ slightly from the list in `archaeology.zig`; the fixture test confirms `.obsidian` and `node_modules` are excluded.

**File classification:**

- `.md` files → pages (subject to entity-ID derivation and wiki-link rewriting)
- Known attachment extensions (images, PDFs, etc.) → attachments (copied to `assets/`)
- `.canvas` files → `unsupported` (inventoried, never converted)
- Everything else → `other` / `unsupported`

**No `.gitignore` or tracked-file awareness.** The tool walks the filesystem directly; it does not consult git to distinguish tracked from ignored files.


| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Vault `.md` pages | Recursive walk, `.md` extension | Yes | Skip-dir names | Source + fixture test |
| Local attachments | Recursive walk, non-`.md` non-`.canvas` known binary extensions | Yes (inventoried + copied) | Skip-dir names | Source + fixture test (`attachmentsmanifest.json`) |
| `.canvas` files | Recursive walk, `.canvas` extension | Inventoried as `unsupported` | Skip-dir names | Source |
| `.obsidian/` directory | Skipped entirely | No | Always excluded | Fixture test assertion |
| `node_modules/` | Skipped entirely | No | Always excluded | Fixture test assertion |
| Symlinks | Policy: not followed (per README) | No | Symlinks excluded | README; not mechanically tested in available evidence |

**Sorting:** Files are discovered via `std.Io.Dir` recursive enumeration. The fixture tests confirm byte-for-byte determinism across two runs but do not expose the intermediate sort order. The entity-ID collision disambiguation is applied after discovery; collisions are resolved deterministically by `entityid` then `vaultpath` order.

## Output artifact model

All outputs are written under `--out &lt;DIR>` (the `outdir`). The vault is never modified.


| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `content/<entity-id>.md` | Boris-frontmatter Markdown | Tool-owned, generated | Derived from vault path; deterministic within a run | Human author, Boris compiler (after review) | Not schema-versioned; format declared `boris-obsidian-migration-lab` v1 |
| `assets/<vault-relative-path>` | Opaque bytes (copy of vault attachment) | Tool-owned, generated | Vault-relative path preserved | Human author, Boris compiler | Byte-identical to source; path sanitization uncertain |
| `report.json` | JSON, format `boris-obsidian-migration-lab` schema `1` | Tool-owned, generated | Stable field order (declared) | Human review, automated tooling | Schema version 1; field-order stability demonstrated by determinism test |
| `REPORT.md` | Markdown human summary | Tool-owned, generated | Derived from report data | Human author | Not independently versioned |
| `attachmentsmanifest.json` | JSON list of attachment copy records | Tool-owned, generated | Deterministic (vault path order) | Human review, tooling | Format not independently versioned |

**Output path for pages:** `content/<entity-id>.md` where `entity-id` is derived from the vault-relative stem with spaces replaced by `-`. Collisions (e.g., `Hello World.md` vs `Hello-World.md`) are disambiguated with `-2`, `-3` suffixes; collisions are also listed under `unsupported_items`.

**No stale-output cleanup** is demonstrated in the available evidence. On repeated runs, new outputs overwrite existing files in the same `outdir`. Whether stale pages from a previous run are removed if the vault shrinks is not demonstrated.

**Optional vs. required outputs:** `report.json`, `REPORT.md`, and `attachmentsmanifest.json` are always emitted. The `content/` and `assets/` trees are only created if there are pages or attachments respectively.

## Serialization and schema behavior

| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `report.json` | `"format": "boris-obsidian-migration-lab"`, `"schema_version": 1` | `emitReportJson` | Top-level fields in declared stable order | Determinism test (byte comparison); field presence asserted by fixture test |
| `attachmentsmanifest.json` | No top-level schema version field (format not independently versioned) | `emitAttachmentsManifest` | Vault-path order | Determinism test (byte comparison) |
| `REPORT.md` | No machine schema | `emitReportMd` | Sections: summary, pages, links, hazards, attachments, humanreview | Determinism test; content spot-checked |
| Per-page `content/*.md` | Boris frontmatter grammar (`id`, `title`, `parent`, `status`, `tags`) + provenance comment | `buildFrontmatter`, `buildProvenanceComment` | Frontmatter before body | Source immutability test; format not schema-versioned |

**JSON serialization:** Uses a handwritten serializer (not `std.json`). String values are escaped via `appendJson` which handles `"`, `\`, `\n`, `\r`, `\t`, `\b`, `\f`, and control characters as `\uXXXX`. Field ordering is deterministic because the serializer emits fields in source-declaration order. Empty arrays are emitted as `[]`. No top-level version field is present in `attachmentsmanifest.json`.

**`report.json` top-level fields (stable order):** `format`, `schema_version`, `tool_version`, `source_vault`, `summary`, `pages`, `links`, `hazards`, `attachments`, `unsupported_items`, `human_review`. (Confirmed by fixture test key presence assertions.)

**Parsing and emission do not share a schema definition.** The emitter is handwritten; there is no round-trip schema or parser generated from the same type definition.

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Byte-identical `report.json` across two runs | Fixture test: `expectEqualStrings(ja, jb)` on `mini-obsidian` | Directly demonstrated | Depends on filesystem enumeration order being stable; cross-platform not tested |
| Byte-identical `REPORT.md` across two runs | Fixture test: `expectEqualStrings(ma, mb)` | Directly demonstrated | Same caveat |
| Byte-identical `attachmentsmanifest.json` across two runs | Fixture test: `expectEqualStrings(aa, ab)` | Directly demonstrated | Same caveat |
| Entity-ID collision disambiguation is deterministic | Disambiguated by `entityid` then `vaultpath`; first keeps base id, others get `-2`, `-3` | Structurally checked (code) | No dedicated adversarial collision fixture for obsidian (contrast with Notion/Starlight) |
| No timestamps or host-environment values in output | No `std.time` or env variable access visible in module | Structurally checked | Not independently verified by test |
| Stable path separators | Forward-slash paths used throughout (Zig string literals) | Structurally checked | Cross-platform byte identity not tested |

**Cross-platform byte identity:** Not claimed. Tests run on a single host. Windows path separator behavior is not tested.

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Output written into vault (input overwrite) | `main.zig` rejects `--vault == --out` | Yes (pre-call check) | Structurally (equality check) | Prefix containment not checked (e.g., `--out` is a subdirectory of `--vault`) |
| Skip-dir exclusion prevents `.obsidian` data in output | Hardcoded skip-dir list | Yes (dir walk) | Fixture test assertion | Other hidden dirs (e.g., `.sync`) not explicitly listed |
| Attachment path traversal in vault | No dedicated traversal fixture for obsidian; hostile-asset-filenames fixture exists only for asset-filename mode | No explicit enforcement visible in available evidence | Not demonstrated | Gap: vault files with `../` in names or nested paths pointing outside vault are not tested |
| Symlink traversal | README states symlinks not followed | No — not mechanically enforced in available evidence | Not demonstrated | No symlink fixture for obsidian |
| Output-path collision for pages | Entity-ID collision disambiguation appends `-2`, `-3` suffixes | Yes (structurally) | Fixture (mini-obsidian `ClashHello World.md` / `ClashHello-World.md`) | Case collision beyond these fixtures not tested |
| Stale output cleanup | Not implemented (no evidence) | No | No | Previous run's generated pages persist if vault shrinks |
| Cleanup on failure | Not demonstrated | No | No | Partial output may remain on I/O error |

**Note on output-inside-source check:** `main.zig` checks `std.mem.eql(u8, vault, outdir)` — exact string equality only. If `outdir` is a subdirectory of `vaultdir`, the check does not catch it. This is consistent with all other migration-lab modes, which apply the same equality-only check.

## Top-level declarations and entry points

| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `format_id` | `pub const` string | Schema identifier for `report.json` | — | `"boris-obsidian-migration-lab"` | Static |
| `schema_version` | `pub const u32` | Report schema version | — | `1` | Static |
| `tool_version` | `pub const` string | Tool version string | — | `"0.1.1"` | Static |
| `max_entity_id_bytes` | `pub const usize` | Maximum entity ID byte length | — | `255` | Static |
| `RunOptions` | `pub const struct` | Input parameters to `run` | — | `vaultdir`, `outdir`, `quiet` | Caller-owned; borrowed by `run` |
| `ConversionClass` | `pub const enum` | Per-page quality classification | — | `.exact`, `.transformed`, `.unsupported`, `.human_review` | Local to run |
| `LinkStatus` | `pub const enum` | Per-link resolution status | — | `.resolved`, `.unresolved`, `.ambiguous`, `.heading_or_block`, `.skipped_fence`, `.unsupported_embed`, `.plugin_template` | Local to run |
| `FrontmatterInfo` | `pub const struct` | Parsed vault frontmatter fields | — | `title`, `parent`, `status`, `tags_raw`, `id_override`, `unknown_keys`, `incompatible`, `notes` | Arena-owned within run |
| `run` | `pub fn` | Primary entry point; full vault migration | `io Io`, `gpa std.mem.Allocator`, `opts RunOptions` | Writes all output artifacts; returns `!void` | Caller (main.zig) owns gpa |
| `pathToEntityId` | `pub fn` | Vault-relative path → Boris entity ID | `allocator`, `vaultrel: []const u8` | Allocated `[]u8` entity ID | Caller-owned |
| `sanitizeEntityId` | (internal/tested) | Replace non-id chars with `-` | `allocator`, `stem` | Allocated `[]u8` | Caller-owned |
| `entityIdIsWikiSafe` | (internal/tested) | Validate entity ID charset | `id` | `bool` | N/A |
| `parseFrontmatter` | (internal) | Parse YAML-like obsidian frontmatter | `allocator`, source bytes | `FrontmatterInfo` | Arena-owned |
| `scanWikiHits` | (internal/tested) | Extract all `&#91;&#91;…]]` wiki targets from body | `allocator`, body | Slice of hit structs | Arena-owned |
| `rewriteBody` | (internal) | Rewrite wiki links and embeds in page body | `allocator`, body, page, index, link log, hazard log, referenced list | `{rewritten_body, class}` | Arena-owned |
| `buildFrontmatter` | (internal) | Emit Boris frontmatter block | `allocator`, id, title, parent, status, tags | `[]u8` | Arena-owned |
| `buildProvenanceComment` | (internal) | Emit `<!-- boris-migration-provenance … -->` comment | `allocator`, vault path, entity id | `[]u8` | Arena-owned |
| `emitReportJson` | (internal) | Serialize `Report` struct to JSON | `allocator`, `Report` | `[]u8` | Caller-frees |
| `emitReportMd` | (internal) | Serialize `Report` struct to Markdown | `allocator`, `Report` | `[]u8` | Caller-frees |
| `emitAttachmentsManifest` | (internal) | Serialize attachment manifest to JSON | `allocator`, slice | `[]u8` | Caller-frees |
| `disambiguateEntityIdCollisions` | (internal) | Append `-2`, `-3`… suffixes to colliding entity IDs | `retain allocator`, `pageslist`, `unsupported` | Mutates page list in-place | Arena-owned |
| `detectBodyHazards` | (internal) | Detect Canvas, Dataview, plugin syntax in body | `allocator`, `exportpath`, body | Slice of hazard records | Arena-owned |
| `copyFileRel` | (internal) | Copy one file from vault to outroot | `io`, vault dir, rel path, out dir, out path | `bool` (success) | N/A |

**`run` initialization:** allocates a retain arena (`std.heap.ArenaAllocator`) on top of `gpa` for all intermediate allocations within the run. At exit (success or error) the arena is deinitialized. The `gpa` is not itself freed by `run`. `io` is the `std.Io` interface passed from `main`. Output directory is opened/created before the vault walk begins.

## Ownership and lifetime model

- **GPA (`gpa`):** Passed in from `main` (backed by `std.process.Init.gpa`). `obsidian.run` does not deinit it. All allocations that outlive the retain arena must be freed before `run` returns.
- **Retain arena:** `std.heap.ArenaAllocator` initialized on `gpa` inside `run`. Used for all intermediate per-page allocations (rewritten body, frontmatter, provenance comment, page records, link findings, hazards, human review, notes). Deinitialized at `run` exit via `defer arena.deinit()`.
- **`gpa`-owned temporaries:** `emitReportJson`, `emitReportMd`, and `emitAttachmentsManifest` allocate on `gpa` and are freed immediately after `writeBytes` via `defer gpa.free(…)`.
- **Borrowed slices:** `RunOptions.vaultdir` and `RunOptions.outdir` are borrowed from the `argv` arena in `main`; `obsidian.run` does not own them.
- **File body reads:** Vault file contents are read into retain-arena buffers; they are not separately freed.
- **Attachment copy:** Uses a stack-based or arena-based intermediate buffer inside `copyFileRel`; no persistent ownership after the copy.
- **Leak freedom:** Not demonstrated by allocator instrumentation. The test allocator is used in unit tests (e.g., `test "pathToEntityId"`), which would catch leaks in those narrow paths. The fixture integration tests in `main.zig` use `std.testing.allocator` but pass it to `run` as the `gpa`, so any arena-escaped allocation would be detected. However, no explicit `leak_check` is asserted.

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--vault` not provided in obsidian mode | `main.zig` before `run` | `std.log.err("obsidian mode requires --vault &lt;DIR>")` + `printUsage()` | Exit 2 | None |
| `--vault == --out` | `main.zig` before `run` | `std.log.err("--out must differ from --vault")` | Exit 2 | None |
| Unknown CLI flag | `main.parseOptions` | `std.log.err("unknown argument, try --help")` | Exit 2 | None |
| I/O failure in `run` (e.g., cannot open vault, cannot write output) | Propagated `!void` from `obsidian.run` | `std.log.err("migration-lab obsidian failed: &lt;ErrorName>")` | Exit 3 | Yes — partial output under `--out` may remain |
| Attachment copy failure | Inside `run`, per-attachment | Entry added to `human_review` with `reason: "attachment_copy_failed"`; `attach_manifest` entry has `copied: false`; run continues | No early exit | Yes — other attachments continue |
| Unresolved/ambiguous wiki link | Inside `rewriteBody` | Recorded in `human_review`; raw link retained in output body; run continues | No early exit | N/A (non-fatal) |
| Entity ID collision | `disambiguateEntityIdCollisions` | Collision listed in `unsupported_items`; output path gets `-2`, `-3` suffix | No early exit | N/A (handled) |
| Canvas file encountered | Vault walk classification | Entry in `unsupported_items` with fixed detail; run continues | No early exit | N/A |

**Diagnostic format:** All user-visible errors are plain `std.log.err(…)` messages to stderr. There is no structured JSON diagnostic output for errors. The `report.json` `human_review` array is a structured list for migration review items, not runtime error diagnostics.

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Entry point; imports this module; provides CLI dispatch and `RunOptions` | `main.zig` → `obsidian.zig` | `main.zig` owns CLI contract |
| `tools/migration-lab/build.zig` | Standalone build; compiles this module into `boris-migration-lab` | Build system → module | `build.zig` is authoritative for build |
| `tools/migration-lab/fixtures/mini-obsidian/` | Fixture corpus for integration tests | Test consumer → fixture | Fixture is input evidence; test assertions are authority |
| `tools/migration-lab/notion.zig` | Sibling module; parallel design pattern (similar `run`, `Report`, `emitReportJson`, frontmatter building) | Sibling; no import relationship | Each module is independent |
| `docs/contracts/frontmatter.md` | Defines the closed Boris frontmatter grammar targeted by emitted pages | Runtime target (no import) | `docs/contracts/frontmatter.md` is authoritative for Boris grammar |
| `docs/MIGRATION.md` | Companion author guide for migration workflow | Documentation | Documentation only |
| `tools/migration-lab/README.md` | Documents tool-level safety rules and invocation | Documentation | README states intent; source is authority for behavior |
| `std.Io` (Zig standard library) | I/O abstraction used throughout | Import | Standard library |

## Security and trust boundaries

**Input trust model:** The vault directory is treated as untrusted filesystem data. File bytes are read and processed by string-scanning routines. The module makes no claim that vault content is safe for arbitrary downstream execution.

**Specific trust boundary behaviors:**

- **Vault `.md` bytes:** Read as opaque bytes for frontmatter parsing and wiki-link scanning. Frontmatter is parsed with a lightweight line-oriented scanner, not a full YAML parser. Deeply nested YAML, multi-line values, anchors, and aliases are not interpreted.
- **Unknown frontmatter keys:** Reported under `unknown_keys` and retained in `human_review`. They are never injected into the output frontmatter block.
- **Wiki link targets:** Processed through the resolution chain. Unresolved targets are left as raw text in the output body, not followed or executed.
- **Embedded Markdown fences:** `scanWikiHits` detects wiki syntax inside code fences and marks hits with `in_fence = true`, leaving them unchanged (classified as `skipped_fence`). This prevents fence-content misclassification. However, the test for this (`test "scanWikiHits"`) covers a simple case; complex nested fences are not tested.
- **Provenance comment:** A `<!-- boris-migration-provenance … -->` HTML comment is appended to every generated page. The vault path and entity ID are embedded here. These values are taken from vault filesystem paths and must not be assumed safe for execution by a downstream system treating HTML comments as trusted metadata.
- **Attachment filenames:** Vault-relative attachment paths are used as output sub-paths under `assets/`. If a vault contains attachment names with shell-special characters or very long paths, the behavior is not explicitly tested.
- **Path traversal:** Vault-relative paths containing `../` or absolute paths are not explicitly rejected in the available evidence. The module derives output paths from vault-relative names; a maliciously named vault file `../../etc/passwd.md` could potentially write outside `outdir`. This is **not mitigated in available evidence** and is an explicit residual gap.
- **Output overwrite:** Existing files in `outdir` are overwritten without staging or backup. No atomic rename. A failed run may leave partial output.
- **Network exfiltration:** No network access is present. Confirmed by absence of `std.net` usage and README statement.
- **Terminal output:** Progress line is printed to stderr via `std.debug.print`. Content includes `opts.outdir` (caller-controlled). No ANSI escape or shell injection mitigation is demonstrated.

## Evidence limitations

- **`obsidian.zig` source was inspected via the source-RAG bundle** (`boris-source-2.md`), which contains the packed source. The source is authoritative; the RAG representation is treated as a faithful copy. No discrepancy between RAG content and a direct file read was tested.
- **`tools/migration-lab/CHANGELOG.md`** was not available in the inspected evidence. Tool version `0.1.1` is visible in the source constant.
- **`tools/migration-lab/build.zig.zon`** was not available. Dependency declarations (if any external deps exist) are unknown; based on `build.zig` source the tool appears to use only the Zig standard library.
- **`AGENTS.md`** and **`docs/STATUS.md`** were not directly inspected. Claims about these documents are not made.
- **Root `build.zig`** was not directly inspected but README and build.zig source confirm separation.
- **Symlink behavior** is documented in README but not mechanically tested; the claim is documentation-only.
- **Path traversal safety** for vault filenames is neither documented as safe nor tested; this is an explicit unknown.
- **Stale-output cleanup** behavior on re-run after vault shrinkage is not demonstrated.
- **Allocation failure paths** are not covered by tests; behavior under `error.OutOfMemory` from the retain arena is not demonstrated.
- **Cross-platform byte identity** is not tested. All fixture tests are assumed to run on a single platform (POSIX-style path separator).
- **`attachmentsmanifest.json` schema versioning:** The format is not independently versioned in the available evidence; schema stability is inferred from the determinism test only.

## Final source assessment

`tools/migration-lab/obsidian.zig` is a self-contained, phase-1 Obsidian vault migration implementation module. Its primary responsibility is transforming a local Obsidian vault into a Boris-compatible Markdown content tree with deterministic entity IDs, rewritten wiki links, copied attachments, and structured human-review reports — entirely without modifying the source vault or coupling to the Boris product compiler.

**Strongest supported guarantees:** Source vault immutability is directly demonstrated by fixture test. Byte-for-byte determinism across two runs is directly demonstrated for `report.json`, `REPORT.md`, and `attachmentsmanifest.json`. The schema identifier `boris-obsidian-migration-lab` version `1` is structurally declared. The tool is provably separate from the Boris product binary at the build level.

**Weakest or least-tested boundaries:** Path traversal safety for vault filenames is neither enforced nor tested. The output-inside-source check is equality-only. Symlink behavior is documented but not mechanically verified. Attachment copy failure and allocation failure paths have no dedicated tests.

**Separation from Boris product runtime:** Complete and structural. No `src/` module is imported. The standalone `build.zig` is not referenced by the root build. Root `zig build test` does not exercise this code.

**Quality of available evidence:** Good for the happy path (mini-obsidian fixture, unit tests for key subroutines). Thin for hostile input, failure modes, and path safety edge cases. No `CHANGELOG.md` or `build.zig.zon` was accessible.

**Most important unresolved question:** Whether vault-relative output paths are contained within `outdir` — specifically, whether a vault file named `../../sensitive.md` could write outside the output directory. This is not addressed by any available test or documented mitigation, and is the highest-priority security gap for any deployment where the vault source is not fully trusted.
