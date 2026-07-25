---
title: "`tools/migration-lab/notion.zig` evidence and cases"
id: docs/tools/migration-lab/notion/evidence-and-cases
parent: docs/tools/migration-lab/notion
status: draft
tags: [boris, zig, tools, evidence, migration-lab, notion]
---

# `tools/migration-lab/notion.zig` evidence and cases

## Operational walkthroughs

### Default Notion migration run

**Invocation:**

```
zig build run -- --mode notion --export fixtures/mini-notion --out ../notion-report
```

**Inputs:**
Unpacked Notion export directory (`fixtures/mini-notion`): Markdown page files with 32-hex ID suffixes in names, nested subdirectories for subpages, local attachment files, optional `.csv` database files.

**Execution path:**
`main.zig → notion.run → walk export tree → parse pages → build Index → for each page: parseFrontmatterLite, rewriteBody, copy media → emit per-page .md, mediamanifest.json, report.json, REPORT.md`

**Outputs:**

- `content/<entity-id>.md` for each discovered Markdown page
- `media/` directory with copied attachment bytes
- `report.json` (schema 1, format `boris-notion-migration-lab`)
- `REPORT.md` (human summary)
- `mediamanifest.json` (deterministic per-media inventory)

**Deterministic properties:**
Byte-identical repeated runs demonstrated for `report.json`, `REPORT.md`, `mediamanifest.json` by the inline integration test.

**Failure behavior:**
IO errors return `!void` and are reported by `main.zig` as `migration-lab notion failed: <errorName>` to stderr, exit code 3.

**Evidence strength:** Directly demonstrated (integration test with `fixtures/mini-notion`).

**Residual gap:** Stale-output cleanup on re-run not verified for notion mode. Symlink handling in export tree uncertain.

***

### Invalid CLI invocation (missing `--export`)

**Invocation:**

```
zig build run -- --mode notion
```

**Execution path:**
`main.zig → parseOptions → switch(.notion) → opts.exportdir is null → log error + printUsage → return ExitCode.usage`

**Outputs:** Usage message to stderr; no files written.

**Failure behavior:** Exit code 2.

**Evidence strength:** Structurally checked (code path in `main.zig` directly shows the null check and usage exit).

**Residual gap:** None significant for this path.

***

### Export equals output directory guard

**Invocation:**

```
zig build run -- --mode notion --export /some/path --out /some/path
```

**Execution path:**
`main.zig → parseOptions → switch(.notion) → string equality check → log error → return ExitCode.usage`

**Evidence strength:** Directly demonstrated by code.

**Residual gap:** Does not check prefix containment (one dir inside the other).

***

## Control flow

```text
process entry (main.zig)
    → initialize allocator and I/O
    → parse CLI arguments (parseOptions)
    → mode dispatch: switch(opts.mode) → .notion branch
    → guard: exportdir != outdir
    → notion.run(io, gpa, {.exportdir, .outdir, .quiet})
        → open export directory (read-only)
        → create output directory
        → walk export tree recursively
            → skip configured directory names and hidden dirs
            → collect PageEntry records (strip Notion IDs, derive entity IDs)
            → collect MediaEntry records (attachment files)
        → build Index (pages + media lookup tables)
        → for each page in discovery order:
            → read page bytes
            → parseFrontmatterLite (extract Boris-compatible fields, flag unknowns)
            → detectBodyHazards (CSV db markers, relation/rollup, synced blocks, embeds)
            → rewriteBody (scan links, percent-decode, resolve via Index, rewrite or flag)
            → derive parent from folder structure when possible
            → copy referenced local media to output media dir
            → build FrontmatterInfo output (closed Boris keys only)
            → emit per-page .md file with provenance comment
            → record PageRecord for report
        → collect all link findings and hazards
        → emit mediamanifest.json
        → emit report.json
        → emit REPORT.md
        → print summary to stderr (unless quiet)
    → return void or propagate error
main.zig maps error → ExitCode.ioerror (exit 3) or success (exit 0)
```


***

## Tests, fixtures, and evidence coverage

### Test table

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "stripNotionPageId title and 32-hex id"` | Unit | Correct ID extraction and title separation | Directly demonstrated | Edge cases: zero-length title, only-ID stem |
| `test "pathToEntityId strips ids and sanitizes nested path"` | Unit | Multi-segment path normalization with ID stripping | Directly demonstrated | Collision behavior |
| `test "percentDecodeAlloc spaces and hex"` | Unit | Percent-decode correctness for `%20` and `%XX` | Directly demonstrated | Malformed sequences, null bytes |
| Integration test (run twice into `outa`, `outb`) | Integration | Byte-identical repeated runs for `report.json`, `REPORT.md`, `mediamanifest.json` | Directly demonstrated | Cross-platform, allocation failure, very large exports |
| Integration test field-presence checks | Integration | `report.json` contains `format`, `schemaVersion`, `pages`, `links`, `hazards`, `media`, `humanReview`, `unsupportedItems`, `resolved`, `ambiguous`, `unresolved`, `databaseCsv`, `relationOrRollup`/`syncedBlock` | Directly demonstrated | Schema completeness, field value correctness |
| Integration test source immutability | Integration | Export tree bytes unchanged after run | Directly demonstrated | Only checks one file |
| Nested page parent inference | Integration | `content/Home/Nested-Guide.md` contains `parent` and `Home` in frontmatter | Directly demonstrated | Deep (>2 hop) hierarchies |
| `fixtures/mini-notion/` (fixture tree) | Fixture | Happy path: nested pages, shared names, CSV database, existing frontmatter | Fixture only (not independently verified as golden) | Hostile inputs, very large pages, symlinks |

**Not demonstrated by available evidence:**

- Stale-output cleanup on re-run for notion mode
- Symlink escape rejection in the export tree
- Allocation-failure recovery
- Malformed frontmatter fence (unclosed `---`) handling in integration
- Cross-platform (Windows) byte identity
- Very large files or very deep directory trees
- CSV database content parsing (not attempted by design)

***
