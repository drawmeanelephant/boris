---
title: "`tools/migration-lab/archaeology.zig` evidence and cases"
id: docs/tools/migration-lab/archaeology/evidence-and-cases
parent: docs/tools/migration-lab/archaeology
status: draft
tags: [boris, zig, tools, evidence, migration-lab, archaeology]
---

# `tools/migration-lab/archaeology.zig` evidence and cases

## Operational walkthroughs

### Default full Astro archaeology

**Invocation:**

```
zig build run -- --mode astro --root ./my-astro-project --out ../migration-report
```

**Inputs:**
Recursive walk of `./my-astro-project`, skipping known tool and VCS directories.

**Execution path:**
`main.zig:main` → `parseOptions` → mode `.astro` dispatch → `archaeology.run(io, gpa, .{.rootdir=…, .outdir=…, .quiet=false})` → filesystem walk → per-file classification via `classifyPath` → frontmatter parsing via `parseFrontmatterLite` for content pages → link extraction via `extractLinks` → hazard collection via `collectHazards` → stitch resolution → entity ID proposal via `proposeEntityId` → `Report` assembly → JSON serialization → write `report.json`, `REPORT.md` to `--out`.

**Outputs:**
`report.json` (machine-readable, format id `boris-astro-migration-lab`, schema 1) and `REPORT.md` (human-readable twin).

**Deterministic properties:**
Byte-identical repeated runs demonstrated for committed fixtures on the same host.

**Failure behavior:**
I/O errors propagate as `error.IoFailure` or the underlying Zig error; `main.zig` catches and logs `std.log.err("migration-lab astro failed: {s}", .{@errorName(err)})` then returns `ExitCode.ioerror` (3).

**Evidence strength:** Directly demonstrated (fixture tests, immutability tests, determinism tests).

**Residual gap:** Symlink handling in walk, stale-output cleanup behavior, and failure atomicity are not confirmed.

***

### Help / usage path

**Invocation:**

```
zig build run -- --help
```

**Inputs:** None.

**Execution path:** `parseOptions` sets `opts.help = true` → `printUsage()` → `return ExitCode.success.int()`.

**Outputs:** Usage text on stderr. Exit code 0.

**Evidence strength:** Directly demonstrated (parseOptions test `const h = try parseOptions(&.{…, "--help"})`).

***

### Invalid CLI invocation (unknown flag)

**Invocation:**

```
zig build run -- --rag
```

**Inputs:** Unknown flag.

**Execution path:** `parseOptions` returns `error.UnknownFlag` → `main` catches → `std.log.err("unknown argument…")` → `printUsage()` → `ExitCode.usage` (2).

**Evidence strength:** Directly demonstrated (`test "parseOptions unknown flag"`).

***

### Dual content roots (ambiguous Astro structure)

**Invocation:**

```
zig build run -- --root ./fixtures/dual-content-roots-astro --out ../out
```

**Inputs:** Fixture containing both `src/content/` and `content/`.

**Execution path:** Both roots discovered → pages from each inventoried → `ambiguouscontentroots` hazard emitted → normal report emission.

**Outputs:** `report.json` with entries from both roots and `ambiguouscontentroots` in `hazards`; free-form `NOTES.md` outside both roots is inventoried as `other`, never as `contentpage` or in `proposedIds`.

**Evidence strength:** Directly demonstrated (`test "astro dual content roots…"`).

***

### Adversarial corpus (Unicode paths, route ambiguity, JSX hazards)

**Invocation:**

```
zig build run -- --root ./fixtures/adversarial-astro --out ../out
```

**Outputs:** Report includes Unicode filenames, `"ambiguous matching dynamic page routes"` signal, missing-file references, and JSX component hazards. Source files remain byte-identical after the run.

**Evidence strength:** Directly demonstrated (`test "astro adversarial corpus…"`).

***

### Absolute-link classification (route vs. public asset)

**Invocation:**

```
zig build run -- --root ./fixtures/absolute-links-astro --out ../out
```

**Outputs:** Site-absolute link `/no-such-page` appears in `brokenLinks` (not `missingAssets`). Present public asset (`/images/hero.png`) not in `missingAssets`. Missing image asset (`/images/missing.png`) appears in `missingAssets`. Valid routes (`/`, `/about`) not in `brokenLinks`.

**Evidence strength:** Directly demonstrated (`test "astro absolute root link…"`).

## Control flow

```text
process entry (main.zig: main)
    → initialize arena allocator (init.arena) and gpa (init.gpa)
    → collect argv slice
    → parseOptions(args) → Options or usage error
    → if opts.help: printUsage(), exit 0
    → mode dispatch: .astro branch
        → guard: rootdir != outdir, else exit 2
        → archaeology.run(io, gpa, RunOptions{rootdir, outdir, quiet})
            → open scan root directory (read-only)
            → recursive walkTree
                → skip known dirs and files
                → classify each file via classifyPath
                → for content pages:
                    → parseFrontmatterLite
                    → collectHazards (frontmatter keys, layout, YAML sequences, nested maps, block scalars)
                    → extractLinks (Markdown + HTML hrefs and image srcs)
                → for page routes:
                    → detect dynamic segments
                → build InventoryEntry, LinkRef, Hazard slices
            → sort discovered paths (mechanism uncertain)
            → resolve stitches (content ↔ route ↔ layout)
            → propose entity IDs via proposeEntityId
            → identify parent–child candidates
            → classify broken links vs. missing assets
            → detect slug conflicts
            → classify absolute links via absoluteToRouteKey / absoluteToPublicPath
            → assemble Report struct
            → serialize report.json (hand-rolled JSON)
            → serialize REPORT.md
            → create --out directory if missing
            → write report.json
            → write REPORT.md
            → if !quiet: print progress to stderr
    → return ExitCode.success (0)
    → on catch: log error name, return ExitCode.ioerror (3)
```

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "parseOptions defaults and astro flags"` | CLI parsing | Default mode `.astro`, `--root`, `--out`, `--quiet` round-trip | Directly demonstrated | Mode interaction with other flags |
| `test "parseOptions unknown flag"` | CLI parsing | Exit-2 path for unknown arguments | Directly demonstrated | — |
| `test "parseOptions invalid mode"` | CLI parsing | Exit-2 path for invalid `--mode` value | Directly demonstrated | — |
| `test "astro entity id proposal from content path"` | `proposeEntityId` | Entity ID derivation for `src/content/`, `src/pages/` | Directly demonstrated | Dynamic segments, unusual extensions |
| `test "astro slug derivation is deterministic"` | `slugFromContentPath` | Collection-relative slug for two inputs | Directly demonstrated | All collection layouts |
| `test "astro path helpers normalize and classify"` | Path helpers | `normalizeRelPath`, `isContentPage`, `isPageRoute`, `isLayout`, `isPublicAsset`, `isSrcAsset`, `contentRootPrefix`, free-form Markdown rejection | Directly demonstrated | Symlink paths, Windows separators |
| `test "astro absolute route key and public path helpers"` | `absoluteToRouteKey`, `absoluteToPublicPath` | Root `/`, `/about`, `/about/` normalization; public path construction | Directly demonstrated | Arbitrary absolute paths |
| `test "astro entity id from root-level content path"` | `proposeEntityId`, `slugFromContentPath`, `collectionFromContentPath` | Root-level `content/` prefix handling | Directly demonstrated | — |
| `test "astro frontmatter hazard detection"` | `parseFrontmatterLite`, `collectHazards` | Hazard count for composite YAML with layout, `parentEntry`, `draft`, nested mapping, YAML sequence | Directly demonstrated | Block scalars, all hazard types individually |
| `test "astro link extraction"` | `extractLinks` | Relative and absolute links, external links filtered | Directly demonstrated | All link forms; image srcset |
| `test "astro fixture scan produces stable report sections"` | `archaeology.run` + `fixtures/mini-astro` | Field presence in `report.json`, `REPORT.md` heading; byte-identical second run | Directly demonstrated | Field values (only presence checked) |
| `test "astro sources are never modified"` | `archaeology.run` + `fixtures/mini-astro` | Source-file immutability | Directly demonstrated | All fixture files (only one checked) |
| `test "astro adversarial corpus…"` | `archaeology.run` + `fixtures/adversarial-astro` | Unicode filename preservation, route ambiguity signal, missing file reference, JSX hazard; source immutability | Directly demonstrated | All adversarial cases |
| `test "astro root-level content discovery determinism…"` | `archaeology.run` + `fixtures/root-content-astro` | Root-level `content/` discovery, byte-identical runs, free-form Markdown exclusion, source immutability | Directly demonstrated | — |
| `test "astro absolute root link, valid route, missing route, real public asset"` | `archaeology.run` + `fixtures/absolute-links-astro` | Absolute link classification (broken route vs. missing asset vs. present asset), source immutability | Directly demonstrated | — |
| `test "astro dual content roots…"` | `archaeology.run` + `fixtures/dual-content-roots-astro` | Dual-root hazard, free-form Markdown exclusion from `proposedIds` and `contentpath` | Directly demonstrated | — |
| `test "astro mini-astro absolute docs is route not missing asset"` | `archaeology.run` + `fixtures/mini-astro` | Regression: `/docs` absolute link classified as route, not missing asset | Directly demonstrated | — |

**Not demonstrated:**

- Allocation-failure recovery
- Symlink behavior in walk
- Stale-output cleanup / failure-mode partial-output recovery
- Cross-platform (Windows path separators, line endings)
- Very large repositories or very large files
- Malformed (non-UTF-8) source files
- CLI missing-value and invalid-value paths for Astro-mode specific arguments
