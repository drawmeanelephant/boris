---
title: "`tools/migration-lab/main.zig` evidence and cases"
id: docs/tools/migration-lab/main/evidence-and-cases
parent: docs/tools/migration-lab/main
status: draft
tags: [boris, zig, tools, evidence, migration-lab, main]
---

# `tools/migration-lab/main.zig` evidence and cases

## Operational walkthroughs

### Default astro mode

**Invocation:**

```
zig build run -- --root fixtures/mini-astro --out ../out-report
```

**Inputs:**
`fixtures/mini-astro/` — Astro project tree with `src/content/docs/**/*.md`, `public/`, `src/assets/`, `package.json`, optional `astro.config.*`.

**Execution path:**
`main` → `parseOptions` → mode check → output-root inequality check → `archaeology.run(io, gpa, {.rootdir, .outdir, .quiet})`.

**Outputs:**
`report.json` (schema `"boris-astro-migration-lab"`, version 1), `REPORT.md`. Output directory created if absent.

**Deterministic properties:**
Paths sorted lexicographically before processing. Two-run byte identity directly demonstrated.

**Failure behavior:**
`archaeology.run` error → `std.log.err` to stderr → `ExitCode.ioerror` (3). Partial output may remain.

**Evidence strength:** Directly demonstrated (byte-equality test, source-immutability test, adversarial corpus test).

**Residual gap:** No test for unreadable files, unwritable output directory, or very deep path trees.

***

### WordPress WXR conversion

**Invocation:**

```
zig build run -- --wxr fixtures/mini-wxr/export.xml --media fixtures/mini-wxr/media --out ../out-wp
```

**Inputs:**
WXR XML file (required), optional media directory, output directory.

**Execution path:**
`main` → `parseOptions` (mode implicitly set to `.wordpress` by `--wxr`) → null-check for `opts.wxrpath` → output equality checks → `wordpress.run(io, gpa, opts)`.

**Outputs:**
`content/*.md` (one per WXR post/page), `report.json`, `REPORT.md`, `mediamanifest.json`. Media files copied from media dir when matched.

**Deterministic properties:**
Uncertain; not tested with a two-run byte comparison in this file.

**Failure behavior:**
`wordpress.run` error → stderr + `ExitCode.ioerror`. Partial output may remain.

**Evidence strength:** Partial coverage — unit tests for `decodeEntities` and `extractNamedElement` present; integration determinism not directly demonstrated.

**Residual gap:** No two-run byte comparison; no test for malformed WXR; no test for missing media directory.

***

### Help / usage path

**Invocation:**

```
zig build run -- --help
```

or

```
zig build run -- -h
```

**Inputs:** None.

**Execution path:** `main` → `parseOptions` (sets `opts.help = true`) → `printUsage()` → returns `ExitCode.success`.

**Outputs:** Usage text to stderr.

**Deterministic properties:** Fixed text output.

**Failure behavior:** Cannot fail.

**Evidence strength:** Directly demonstrated (`test "parseOptions defaults and astro flags"` checks `opts.help = true`).

**Residual gap:** None significant.

***

### Invalid CLI invocation

**Invocation:**

```
zig build run -- --rag
```

**Execution path:** `main` → `parseOptions` → `error.UnknownFlag` → `std.log.err("unknown argument…")` + `printUsage()` → `ExitCode.usage` (2).

**Evidence strength:** Directly demonstrated (`test "parseOptions unknown flag"` and `test "parseOptions invalid mode"`).

**Residual gap:** Exact stderr message text not tested.

***

### Starlight conversion with compile verification

**Invocation:**

```
zig build run -- --mode starlight --root fixtures/mini-starlight --out ../out-sl --locale en --max-pages 32 --boris ../../zig-out/bin/boris
```

**Inputs:**
Starlight project root, `en` locale, page cap, optional Boris binary path.

**Execution path:**
`main` → output-root inequality check → `starlight.run(io, gpa, opts)`. Inside `starlight.run`: discovery, parsing, link rewrite, asset migration, manifest emission, optional `tryCompileWithBoris` subprocess.

**Outputs:**
Converted content pages, `routemap.json`, `unsupportedmanifest.json`, `assetsmanifest.json`, `selectionmanifest.json`, `boundarymanifest.json`, `compilereport.json`, `report.json`, `REPORT.md`.

**Deterministic properties:**
Lexicographic sort of markdown files, entity-ID sort of pages (structurally checked). Compile verification result is subprocess-dependent.

**Failure behavior:**
Locale not `en` → `error.LocaleNotSupported` → exit 3. `max-pages` out of range → exit 3. Boris binary not found → compile step skipped, not an error. Subprocess failure → `compilereport.json` records failure status.

**Evidence strength:** Partial coverage — CLI parsing directly demonstrated; integration determinism uncertain for starlight specifically within `main.zig`'s test block; `starlight.zig` has its own tests.

**Residual gap:** No two-run byte comparison visible in `main.zig` for starlight mode output.

***

## Control flow

```text
process entry (main)
    → init arena (cold), gpa, io from std.process.Init
    → collect argv via init.minimal.args.toSlice(cold)
    → parseOptions(args)
        → for each arg: match flag via startsWith / eql
        → set Options fields; infer mode from mode-implying flags (--wxr, --dump, --vault, --export, --dump, --filed-root, --content)
        → return ParseError on unknown flag / missing value / invalid value
    → on ParseError: log, printUsage, return ExitCode.usage
    → if opts.help: printUsage, return ExitCode.success
    → switch opts.mode:
        .astro       → check --out != --root; archaeology.run(...)
        .wordpress   → require --wxr; check --out != --wxr, --media; wordpress.run(...)
        .instagram   → require --dump; check --out != --dump; instagram.run(...)
        .obsidian    → require --vault; check --out != --vault; obsidian.run(...)
        .notion      → require --export; check --out != --export; notion.run(...)
        .filed       → require --filed-root; check --out != --filed-root; filed.run(...)
        .starlight   → check --out != --root; starlight.run(...)
        .assetfilename → check --out != --root; assetfilename.run(...)
        .themearchaeology → check --out != --root; themearchaeology.run(...)
        .themematerialize → require --ledger; check --out != --root && --out != --ledger; themematerialize.run(...)
        .wordpresstheme → check --out != --root; wordpresstheme.run(...)
        .linkaudit   → check --out != --root; linkaudit.run(...)
        .frontmatterreview → require --content; check --out != --content; frontmatterreview.run(...)
    → on run error: log errorName, return ExitCode.ioerror
    → return ExitCode.success
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "parseOptions defaults and astro flags"` | Unit | Defaults, `--help`, `--root`, `--out`, `--quiet` | Directly demonstrated | Interaction with mode dispatch |
| `test "parseOptions wordpress flags"` | Unit | `--wxr` implies mode, split and fused forms | Directly demonstrated | Integration |
| `test "parseOptions instagram flags"` | Unit | `--dump` implies mode, both forms | Directly demonstrated | Integration |
| `test "parseOptions obsidian flags"` | Unit | `--vault` implies mode, alias `vault` | Directly demonstrated | Integration |
| `test "parseOptions notion flags"` | Unit | `--export` implies mode, aliases | Directly demonstrated | Integration |
| `test "parseOptions filed flags"` | Unit | `--filed-root` implies mode | Directly demonstrated | Integration |
| `test "parseOptions asset-filename flags"` | Unit | `--mode asset-filename`, alias `assets` | Directly demonstrated | Integration |
| `test "parseOptions theme-archaeology flags"` | Unit | Aliases `theme`, `theme-inventory` | Directly demonstrated | Integration |
| `test "parseOptions wordpress-theme flags"` | Unit | Alias `kubrick-theme` | Directly demonstrated | Integration |
| `test "parseOptions starlight flags"` | Unit | `--locale`, `--max-pages`, `--boris`, alias `sl` | Directly demonstrated | Integration |
| `test "parseOptions frontmatter-review flags"` | Unit | `--content` implies mode, aliases | Directly demonstrated | Integration |
| `test "parseOptions unknown flag"` | Unit | `error.UnknownFlag` for `--rag` | Directly demonstrated | — |
| `test "parseOptions invalid mode"` | Unit | `error.InvalidValue` for `--mode hugo` | Directly demonstrated | — |
| `test "astro fixture scan produces stable report sections"` | Integration | Report keys present; two-run byte identity for `report.json` + `REPORT.md` | Directly demonstrated | Cross-platform; all edge cases |
| `test "astro sources are never modified"` | Integration | Input file unchanged after `run` | Directly demonstrated | Other modes |
| `test "astro adversarial corpus…"` | Integration | Unicode preserved; route ambiguity reported; missing file; JSX component detected; source unchanged | Directly demonstrated | All adversarial patterns |
| `test "astro root-level content discovery determinism"` | Integration | Root `content/` prefix discovered; `NOTES.md` excluded; two-run byte identity | Directly demonstrated | Cross-platform |
| `test "astro absolute root link, valid route…"` | Integration | Absolute route classification; missing asset vs broken link categorization | Directly demonstrated | All link types |
| `test "astro dual content roots…"` | Integration | Both roots discovered; ambiguous-root flag; stray `NOTES.md` excluded | Directly demonstrated | — |
| `test "astro mini-astro absolute docs is route…"` | Integration | `docs` not misclassified as missing asset; real missing image reported | Directly demonstrated | — |
| `test "astro entity id proposal…"` | Unit | `proposeEntityId` path-to-id mapping | Directly demonstrated | — |
| `test "astro slug derivation is deterministic"` | Unit | `slugFromContentPath` | Directly demonstrated | — |
| `test "astro path helpers…"` | Unit | `isContentPage`, `isPageRoute`, `isLayout`, `isPublicAsset`, `isSrcAsset`, `contentRootPrefix` | Directly demonstrated | — |
| `test "astro absolute route key…"` | Unit | `absoluteToRouteKey`, `absoluteToPublicPath` | Directly demonstrated | — |
| `test "astro entity id from root-level content path"` | Unit | Root-level entity id, slug, collection derivation | Directly demonstrated | — |
| `test "astro frontmatter hazard detection"` | Unit | `parseFrontmatterLite`, `collectHazards` | Directly demonstrated | — |
| `test "astro link extraction"` | Unit | Relative link extraction; external link excluded | Directly demonstrated | — |
| `test "wordpress decode entities"` | Unit | HTML entity decoding | Directly demonstrated | — |
| `test "wordpress extractNamedElement CDATA"` | Unit | CDATA extraction | Directly demonstrated | — |
| Fixture: `fixtures/hostile-asset-filenames/` | Integration (via `assetfilename.zig`) | Traversal, collision, symlink, percent-encoded, unicode filenames | Partially — exercised by test declarations via `refAllDecls` | Direct `main.zig` integration test absent |
| `instagram` module tests | In-module | Media classification, entity ID, fence safety | Directly demonstrated in module | Excluded from `main.zig` `refAllDecls` — leaks under testing allocator |
| `fixtures/wordpress-theme/mini-wordpress-kubrick` | Integration (via `wordpresstheme.zig`) | Two-run determinism; PHP dynamic findings preserved; prototype slots | Directly demonstrated | — |
| `fixtures/fm-review-*/` | Integration (via `frontmatterreview.zig`) | Known/unknown key detection; open-fence fixture | Partially | — |

**Not tested in `main.zig` or in evidence read:**

- Exit codes asserted by test assertions (only CLI parsing outcomes tested)
- `--out` equals `--root` guard paths
- Cleanup on partial failure
- Allocation failure paths (no `FailingAllocator` usage observed)
- Cross-platform byte identity
- Stale output cleanup

***
