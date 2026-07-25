---
title: "`tools/migration-lab/obsidian.zig` evidence and cases"
id: docs/tools/migration-lab/obsidian/evidence-and-cases
parent: docs/tools/migration-lab/obsidian
status: draft
tags: [boris, zig, tools, evidence, migration-lab, obsidian]
---

# `tools/migration-lab/obsidian.zig` evidence and cases

## Operational walkthroughs

### Default obsidian vault migration

**Invocation:**

```
zig build run -- --vault fixtures/mini-obsidian --out ../obs-report
```

**Inputs:**
Vault directory at `fixtures/mini-obsidian`. Contains `.md` pages (flat and nested), attachment (`Attachments/diagram.png`), `.obsidian/` config dir, Dataview demo page, Canvas reference (if present), clash pages (`Clash/Hello World.md` and `Clash/Hello-World.md`).

**Execution path:**
`main` → parses CLI → calls `obsidian.run(io, gpa, {.vaultdir = "fixtures/mini-obsidian", .outdir = "../obs-report", .quiet = true})` → walk vault, classify files → build page index and attachment list → `disambiguateEntityIdCollisions` → for each page: `parseFrontmatter`, `detectBodyHazards`, `rewriteBody` (calls `scanWikiHits` internally), `buildFrontmatter`, `buildProvenanceComment`, `writeBytes` to `content/<entity-id>.md` → for each attachment: `copyFileRel` to `assets/<vault-path>` → `emitReportJson` → `writeBytes(report.json)` → `emitReportMd` → `writeBytes(REPORT.md)` → `emitAttachmentsManifest` → `writeBytes(attachmentsmanifest.json)`.

**Outputs:**

- `../obs-report/content/<entity-id>.md` — one file per vault `.md` page
- `../obs-report/assets/Attachments/diagram.png` — copied attachment bytes
- `../obs-report/report.json` — schema v1 JSON report
- `../obs-report/REPORT.md` — human-readable report
- `../obs-report/attachmentsmanifest.json` — attachment copy manifest

**Deterministic properties:**
Byte-for-byte identical output on repeated runs (directly demonstrated by fixture test for `report.json`, `REPORT.md`, `attachmentsmanifest.json`).

**Failure behavior:**
If `obsidian.run` returns an error, `main.zig` prints `"migration-lab obsidian failed: <error-name>"` to stderr and exits with code 3. Partial output may remain. No rollback or staging mechanism is present.

**Evidence strength:** Directly demonstrated (fixture integration test `test "obsidian"` in `main.zig`).

**Residual gap:** The fixture does not include a hostile vault with traversal names, symlinks, or deep nesting levels. Attachment copy failure is structurally handled (produces `copied: false` in manifest and `humanreview` entry) but no test triggers this path.

***

### Wiki-link rewrite — resolved

**Invocation:** Any obsidian run where vault pages contain `&#91;&#91;Note]]` or `&#91;&#91;Note|alias&#93;&#93;` targeting resolvable vault notes.

**Execution path:** `rewriteBody` → `scanWikiHits` produces hit list → for each hit, applies ten-rule resolution chain → resolved links become Boris entity-ID references → `LinkStatus.resolved` counted in `n_resolved`.

**Evidence strength:** Directly demonstrated (unit tests for `pathSuffixMatch`, `isPluginTemplateWikiTarget`, `scanWikiHits`; fixture test confirms `"resolved"` key in `report.json`).

**Residual gap:** Not all ten resolution rules have independent unit tests. Rules 8–10 (ambiguous, unresolved, plugin template) are covered by fixture data but not isolated unit tests.

***

### Unresolved / ambiguous wiki links

**Invocation:** Vault pages containing `&#91;&#91;Missing Note]]` or `&#91;&#91;Shared&#93;&#93;` where `Shared` matches multiple vault paths.

**Execution path:** `rewriteBody` → link left raw in output body → `LinkStatus.unresolved` or `.ambiguous` → appended to `humanreview` with `reason` field.

**Evidence strength:** Directly demonstrated — fixture test asserts `"ambiguous"` and `"unresolved"` keys in `report.json`; `fixtures/mini-obsidian` includes `AmbiguousShared.md` and `OtherShared.md` to exercise this.

***

### Plugin template / Dataview / Canvas

**Invocation:** Vault pages containing Templater `&#123;&#123;tp.file.title&#125;&#125;` wiki targets, `dataview` code blocks, or `.canvas` files.

**Execution path:** `isPluginTemplateWikiTarget` → `LinkStatus.plugin_template` (for wiki targets); `detectBodyHazards` → hazard record for dataview/canvas body content; `.canvas` files → `unsupported` category.

**Evidence strength:** Directly demonstrated — unit tests for `isPluginTemplateWikiTarget`; fixture test asserts `"dataview"` and `"canvas"` keys in `report.json`.

***

### Help / usage

**Invocation:** `boris-migration-lab --help`

**Execution path:** `main` parses `--help` → `printUsage()` → exits 0. `obsidian.zig` is not called.

**Evidence strength:** Directly demonstrated (unit test `test "parseOptions defaults and astro flags"` checks `h.help`).

***

### Invalid CLI invocation

**Invocation:** e.g., `--mode obsidian` without `--vault`, or `--vault` without a value.

**Execution path:** `main.parseOptions` returns `error.MissingValue` or `error.UnknownFlag` → `main` prints error message + usage hint → exits 2. `obsidian.run` is never called.

**Evidence strength:** Directly demonstrated (unit tests `test "parseOptions unknown flag"` and `test "parseOptions invalid mode"`).

## Control flow

```text
process entry (main.zig)
    → init arena allocator and gpa (std.process.Init)
    → collect argv to []const []const u8
    → parseOptions(args)
        on error: print diagnostic, printUsage(), return ExitCode.usage
    → if opts.help: printUsage(), return ExitCode.success
    → switch opts.mode → .obsidian branch:
        → assert opts.vault_dir != opts.out_dir (else ExitCode.usage)
        → obsidian.run(io, gpa, RunOptions{…})
            → allocate retain arena on gpa
            → open/create outdir (output root)
            → open vaultdir (read-only)
            → walk vault tree (recursive, skip known dirs)
                → classify each file: .md → page, attachment ext → attachment,
                  .canvas → unsupported, other → unsupported
            → build page index (vault path, entity id, output path, basename)
            → build attachment list (vault path, output path)
            → disambiguateEntityIdCollisions(retain, pageslist, unsupported)
            → for each page:
                → read body bytes from vault
                → parseFrontmatter(retain, body)
                → resolve parent entity (from frontmatter or folder hierarchy)
                → detectBodyHazards(retain, export_path, body)
                → rewriteBody(retain, vault_path, body, page, index, page_links, hazards, referenced)
                    → scanWikiHits(retain, body)
                    → for each hit: apply 10-rule resolution chain
                    → emit rewritten body with resolved targets or raw original
                → buildFrontmatter(retain, id_field, title, parent, status, tags_raw)
                → buildProvenanceComment(retain, vault_path, entity_id)
                → assemble final Markdown (frontmatter + provenance + body)
                → writeBytes(io, outroot, page.output_path, md.items)
                → append to page_records, all_links, all_hazards, human_review
            → for each attachment:
                → copyFileRel(io, vault, attachment.vault_path, outroot, attachment.output_path)
                → append to attach_manifest (with copied: bool, referenced: bool)
            → count resolved/unresolved/ambiguous link stats
            → build Report struct
            → emitReportJson(gpa, report) → writeBytes(io, outroot, "report.json", json)
            → emitReportMd(gpa, report)   → writeBytes(io, outroot, "REPORT.md", mdrep)
            → emitAttachmentsManifest(gpa, …) → writeBytes(io, outroot, "attachmentsmanifest.json", man)
            → if !quiet: print progress line to stderr
            → return void (or !void on error)
        on error: std.log.err("migration-lab obsidian failed: …"), return ExitCode.io_error
    → return ExitCode.success
```

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "pathToEntityId"` (obsidian.zig) | Unit | Spaces → `-`, nested paths, `.md` stripped | Directly demonstrated | Non-ASCII, very long paths |
| `test "sanitizeEntityId wiki-safe charset"` (obsidian.zig) | Unit | `Hello World!` → `Hello-World`; wiki-safe validation | Directly demonstrated | Unicode normalization, control chars |
| `test "pathSuffixMatch exact and nested suffix"` (obsidian.zig) | Unit | Suffix match at path boundary; non-boundary rejection | Directly demonstrated | Deep nesting |
| `test "isPluginTemplateWikiTarget"` (obsidian.zig) | Unit | Templater `&#123;&#123;…&#125;&#125;` and `<% … %>` patterns detected | Directly demonstrated | All Templater syntax variants |
| `test "scanWikiHits link alias embed and fence"` (obsidian.zig) | Unit | Alias, embed `!&#91;&#91;…]]`, in-fence skip, heading/block | Directly demonstrated | Malformed wiki syntax, Unicode targets |
| `test "obsidian"` (main.zig, fixture) | Integration | Full `run` on `mini-obsidian`; byte determinism (2 runs); source immutability; `report.json` schema keys; skip-dir exclusion; `attachmentsmanifest.json` determinism; `REPORT.md` determinism | Directly demonstrated | Hostile input, symlinks, very large vaults, copy failure, path traversal |
| `fixtures/mini-obsidian` | Fixture corpus | Flat pages, nested pages, attachments, `.obsidian/`, clash names (`Hello World.md` / `Hello-World.md`), Dataview demo, ambiguous/shared names, path-suffix probe, Templater template | Directly demonstrated | Traversal filenames, symlinks, large binary attachments |

**No golden output files** tracked for obsidian (unlike e.g. some WordPress fixture expected outputs). Determinism is verified by run-A vs run-B comparison, not against a committed expected file.

**No hostile-obsidian fixture** comparable to `fixtures/hostile-asset-filenames` or `fixtures/hostile-starlight`. Path safety edge cases (traversal names, symlinks, control characters in vault filenames) are not exercised.
