---
title: "`tools/migration-lab/instagram.zig` evidence and cases"
id: docs/tools/migration-lab/instagram/evidence-and-cases
parent: docs/tools/migration-lab/instagram
status: draft
tags: [boris, zig, tools, evidence, migration-lab, instagram]
---

# `tools/migration-lab/instagram.zig` evidence and cases

## Operational walkthroughs

### Default Instagram migration run

**Invocation:**

```
zig build run -- --mode instagram --dump ./fixtures/mini-instagram --out ../ig-report
```

**Inputs:**

- Unpacked export under `./fixtures/mini-instagram/your_instagram_activity/content/`
- JSON files: `posts1.json`, `posts2.json`, `reels.json`, `stories.json`, `othercontent.json`
- Local media under `./fixtures/mini-instagram/media/`

**Execution path:**
`main.zig` → `instagram.run(io, gpa, opts)` → arena init → open dump dir → open out dir → delete stale lab output → walk and parse JSON/HTML files → for each record: derive entity ID, classify, repair encoding if needed, check media URI safety, copy media bytes, emit Markdown page → build `Report`, `MediaManifestEntry` arrays → emit `report.json`, `REPORT.md`, `mediamanifest.json`, theme scaffold → return.

**Outputs:**

- `content/instagram.md` (trunk stub)
- `content/instagram/<kind>-<id>.md` per record
- `theme/layouts/main.html`, `theme/layouts/footer.html`, `theme/assets/css/site.css`
- `theme/assets/media/<path>` for each safely resolved media URI (bytes copied verbatim)
- `report.json`, `REPORT.md`, `mediamanifest.json`

**Deterministic properties:**
Record processing order follows sorted file discovery; entity-ID derivation is deterministic per input. No wall-clock timestamps in generated output beyond export-provided `creation_timestamp` values.

**Failure behavior:**
I/O errors propagate as Zig errors → `main.zig` catches and maps to `ExitCode.ioerror` (3) with a message on stderr. Unsafe media URIs do not abort the run; the record is classified `humanreview` and the URI is logged in the report.

**Evidence strength:** Partial coverage — fixture integration test exercises the mini-instagram tree; hostile-instagram fixture exercises path-traversal rejection. No confirmed repeated-run byte-comparison test for this specific mode.

**Residual gap:** No confirmed golden-output comparison test for `report.json` or individual page bytes. Memory leak under testing allocator noted in `main.zig` comment. Symlink behavior in dump tree not covered.

***

### Help / usage path

**Invocation:**

```
boris-migration-lab --help
```

**Execution path:**
`main.zig` → `parseOptions` sets `opts.help = true` → `printUsage()` → exit 0. `instagram.zig` is not reached.

**Evidence strength:** Directly demonstrated by `test "parseOptions defaults and astro flags"` in `main.zig`.

***

### Invalid CLI invocation (missing `--dump`)

**Invocation:**

```
boris-migration-lab --mode instagram --out /tmp/out
```

**Execution path:**
`main.zig` switch on `.instagram` → `opts.dumpdir orelse { stderr error; return ExitCode.usage.int }`.

**Failure behavior:**
Stderr message: `instagram mode requires --dumpDIR`. Exit code 2.

**Evidence strength:** Structurally checked; not independently unit-tested for this specific message.

***

### Hostile media URI rejection

**Invocation:**

```
zig build run -- --mode instagram --dump ./fixtures/hostile-instagram --out ../hostile-out
```

**Execution path:**
`run` → for each record, `isSafeMediaUri(uri)` → if false: record classified `humanreview`; media not read; report entry: `"status": "unsafe media uri rejected"`.

**Evidence strength:** Documented in README and source comment; `fixtures/hostile-instagram/` exists; integration test exercises it. Specific checks for `..`, `/`, `\`, drive prefix are structurally enforced by `isSafeMediaUri`.

**Residual gap:** Percent-encoded traversal (`%2e%2e`) not confirmed as tested. Symlink traversal not addressed.

***

### Meta-escaped Latin-1 caption repair

**Execution path:**
`parseMediaObject` → `repairMetaEscapedUtf8(retain, raw_caption)` → if `TextRepair.repaired`: page marked `meta-latin1-repaired` in provenance, conversion class upgraded to `transformed`; if `TextRepair.residue` (mojibake remains after repair attempt): marked `suspected-mojibake-unrepaired`, classified `humanreview`.

**Evidence strength:** Structurally checked by implementation logic; `fixtures/mini-instagram/your_instagram_activity/content/posts2.json` contains the synthetic escaped caption (`café☺`); fixture integration test exercises it. No separate unit test for `repairMetaEscapedUtf8` confirmed.

***

## Control flow

```text
process entry (main.zig: pub fn main)
    → initialize arena + gpa
    → parse CLI arguments (parseOptions)
    → dispatch on mode → .instagram
    → validate --dump != --out
    → instagram.run(io, gpa, opts)
        → init arena over gpa
        → validate opts.dumpdir != opts.outdir
        → open dump dir (read-only)
        → open / create out dir
        → delete stale lab-owned output files under out dir
        → walk dump content directory
            → for each JSON/HTML source file matching known names:
                → parse JSON (std.json) or parse HTML (parseHtmlPostsFile)
                → for each record object:
                    → parseRecordObject / parseMediaObject
                    → repairMetaEscapedUtf8 on caption and media titles
                    → classify ConversionClass (exact / transformed / unsupported / humanreview)
                    → derive entity ID via extractDurableId or fallbackHashId
                    → check isSafeMediaUri for each media URI
                    → if safe: copyFileRel dump→out/theme/assets/media/
                    → build IgRecord, append to records list
        → sort records by entity ID (determinism)
        → emit content/instagram.md (trunk stub)
        → for each record:
            ```
            → emit content/instagram/<kind>-<id>.md
            ```
                → write Boris closed frontmatter (escapeFmValue)
                → write provenance HTML comment
                → write caption body in fenced block (fence sized to outrank any backtick run in caption)
                → write media references
        → emit theme scaffold files (layouts, css)
        → build Report struct
        → emit report.json (hand-serialized JSON via jsonEscapeAppend)
        → emit REPORT.md
        → emit mediamanifest.json
        → arena.deinit
        → return void (or propagate !void error)
    → on error: main.zig logs errorName, returns ExitCode.ioerror
    → on success: returns ExitCode.success
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `fixtures/mini-instagram/` integration run | Full pipeline over synthetic export | Basic happy-path conversion of all record kinds; encoding repair; missing media handling; duplicate basenames; Unicode captions | Partial coverage (structurally exercised) | Byte-for-byte repeated-run identity; exact golden output match |
| `fixtures/hostile-instagram/` | Path traversal rejection | `isSafeMediaUri` rejects `..`, absolute, backslash, drive-prefix URIs | Partial coverage | Percent-encoded traversal; symlink traversal |
| `parseOptions` tests in `main.zig` | CLI parsing for instagram flags | `--dump` implies mode; space-separated and `--dump=` forms work | Directly demonstrated | Missing-dump error path |
| `test "parseOptions instagram flags"` | CLI unit | Both `--dump<val>` and `--dump <val>` forms, mode inference | Directly demonstrated | Nothing about run behavior |
| Allocator leak acknowledgement in `main.zig` | Meta-test | Known leak exists under testing allocator | Documented (comment) | Leak source not identified; leak freedom not demonstrated |
| Source immutability (other modes) | Pattern in test suite | Other modes confirm source immutability via before/after byte compare | Partial coverage by analogy | Instagram-specific source-immutability test not confirmed |
| Repeated-run determinism (other modes) | Pattern in test suite | Other modes (Astro, Starlight, etc.) have explicit second-run byte-comparison tests | Not demonstrated for Instagram | Instagram-specific determinism test not confirmed |


***
