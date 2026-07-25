---
title: "`tools/migration-lab/build.zig` evidence and cases"
id: docs/tools/migration-lab/build/evidence-and-cases
parent: docs/tools/migration-lab/build
status: draft
tags: [boris, zig, tools, evidence, migration-lab, build]
---

# `tools/migration-lab/build.zig` evidence and cases

## Operational walkthroughs

### Default Astro archaeology

**Invocation:**

```
zig build run -- --mode=astro --root=./fixtures/mini-astro --out=../migration-report
```

**Inputs:** Astro project tree at `--root`; `src/content/` and/or `content/` Markdown files; `src/pages/`, `src/layouts/`, `public/`, `src/assets/` for inventory.

**Execution path:** `main` → `parseOptions` → `archaeology.run(io, gpa, opts)`. Walk tree, classify files, parse frontmatter, extract links, detect hazards, sort by path, emit `report.json` + `REPORT.md`.

**Outputs:** `report.json` (schema v1, `boris-astro-migration-lab`), `REPORT.md`. No Markdown files written (read-only archaeology).

**Deterministic properties:** Stable path sort; byte-identical repeated runs directly demonstrated.

**Failure behavior:** I/O failure → exit 3 with error name. `--out` equals `--root` → exit 2. Missing root directory → error propagated as `io_error`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Absolute-path and symlink behavior only partially covered. astro.config evaluation excluded by design.

***

### WordPress WXR conversion

**Invocation:**

```
zig build run -- --wxr=./fixtures/mini-wxr/export.xml --media=./fixtures/mini-wxr/media --out=../wp-report
```

**Inputs:** WXR XML file; optional local media directory; `--out` for output.

**Execution path:** `main` → `wordpress.run(io, gpa, opts)`. Parse XML, decode entities, convert post/page bodies, copy verified media, emit converted Markdown tree + manifests.

**Outputs:** `content/*.md`, `content/stem.assets/` (media), `report.json` (schema v3), `REPORT.md`, `mediamanifest.json`.

**Deterministic properties:** Deterministic slug derivation; media manifest field order stable. Byte-identity between repeated runs not explicitly tested in available evidence.

**Failure behavior:** Missing `--wxr` → exit 2. I/O failure → exit 3.

**Evidence strength:** Directly demonstrated (unit-wxr, mini-wxr, media-wxr, adversarial-wxr fixtures).

**Residual gap:** Hostile WPTT fixtures noted as offline-only; not in CI.

***

### Starlight conversion with optional compile verification

**Invocation:**

```
zig build run -- --mode=starlight --root=./fixtures/dogfood-starlight --out=../sl-out --locale=en --max-pages=80
```

**Inputs:** Starlight project root; locale key; page cap; optionally `--boris` path.

**Execution path:** `main` → `starlight.run(io, gpa, opts)`. Discover locale content root, collect Markdown, parse, strip untrusted blocks, transform MDX, resolve links, migrate page images, emit content tree + all manifests. Optionally invoke `boris` subprocess for compile verification.

**Outputs:** `content/*.md`, page `stem.assets/`, `routemap.json`, `selectionmanifest.json`, `unsupportedmanifest.json`, `assetsmanifest.json`, `navflatten.json`, `provenancemanifest.json`, `linkreview.json`, `headingfragments.json`, `boundarymanifest.json`, `compilereport.json`, `report.json`, `REPORT.md`.

**Deterministic properties:** Lexicographic sort of candidate pages; entity-id sort in routemap; boundary manifest multi-key sorted.

**Failure behavior:** Non-`en` locale → `error.LocaleNotSupported`. `--max-pages` < 1 or > 200 → `error.InvalidMaxPages`. Boris binary not found → compile step skipped (not fatal). I/O failure → exit 3.

**Evidence strength:** Directly demonstrated (dogfood-starlight fixture, hostile-starlight fixture).

**Residual gap:** Real-site smoke tests documented as operator-only, not CI. Subprocess error behavior on CI partial.

***

### Help path

**Invocation:**

```
boris-migration-lab --help
```

**Execution path:** `main` → `parseOptions` (sets `help=true`) → `printUsage()` → return exit 0.

**Outputs:** Usage text to stderr.

**Evidence strength:** Directly demonstrated (`test parseOptions defaults and astro flags` verifies `--help` sets `opts.help`).

**Residual gap:** Exact output format not golden-compared.

***

### Invalid CLI invocation

**Invocation:**

```
boris-migration-lab --rag
```

**Execution path:** `main` → `parseOptions` returns `error.UnknownFlag` → print "unknown argument try --help" → `printUsage()` → return exit 2.

**Evidence strength:** Directly demonstrated (`test parseOptions unknown flag`).

**Residual gap:** Exit code 2 not asserted in test; only error type checked.

***

## Control flow

```text
process entry (main)
    → initialize arena allocator and GPA (std.process.Init)
    → read process args → copy into ArrayList
    → parseOptions(args)
        → iterate argv: match flags, assign Options fields
        → mode aliases resolved via Mode.parse()
        → return ParseError on unknown flag / missing value / invalid value
    → on ParseError: print error, printUsage(), return exit 2
    → if opts.help: printUsage(), return exit 0
    → switch opts.mode:
        → for each mode:
            → validate required mode-specific inputs (exit 2 if missing)
            → check --out ≠ input paths (exit 2 if equal)
            → call mode.run(io, gpa, RunOptions{ ... })
                → walk input tree
                → classify / parse / transform
                → sort paths / records deterministically
                → build output artifacts in arena
                → write files to --out directory
                → optionally invoke subprocess (starlight only)
                → print progress unless --quiet
            → on error: std.log.err, return exit 3
    → return exit 0
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test parseOptions defaults and astro flags` | Unit | Default values, `--root`, `--out`, `--quiet` parsing | Directly demonstrated | Exact exit code on failure |
| `test parseOptions wordpress flags` | Unit | `--wxr`, `--media`, mode implication | Directly demonstrated | — |
| `test parseOptions instagram/obsidian/notion/filed/asset-filename/theme-archaeology/wordpress-theme/starlight/frontmatter-review flags` | Unit | All flag parsing including aliases | Directly demonstrated | — |
| `test parseOptions unknown flag` | Unit | `UnknownFlag` error return | Directly demonstrated | Exit code 2 (not asserted) |
| `test parseOptions invalid mode` | Unit | `InvalidValue` error return | Directly demonstrated | — |
| `test astro entity id proposal` | Unit | `proposeEntityId` correctness | Directly demonstrated | — |
| `test astro slug derivation is deterministic` | Unit | `slugFromContentPath` stability | Directly demonstrated | Cross-platform |
| `test astro path helpers` | Unit | `normalizeRelPath`, classification predicates | Directly demonstrated | — |
| `test astro fixture scan produces stable report sections` + byte-comparison | Integration | Determinism (byte-identical repeated runs), key presence in JSON | Directly demonstrated | Timestamp absence, all field values |
| `test astro sources are never modified` | Integration | Source immutability | Directly demonstrated | All modes |
| `test astro adversarial corpus` | Integration | Unicode preservation, route ambiguity reporting, source immutability | Directly demonstrated | All modes |
| `test astro root-level content discovery determinism source immutability` | Integration | Root-level `content/` discovery, determinism, NOTES.md exclusion | Directly demonstrated | — |
| `test astro absolute root link / route / missing route / public asset` | Integration | Absolute link classification: broken vs. missing asset distinction | Directly demonstrated | — |
| `test astro dual content roots` | Integration | Dual-root hazard detection, NOTES.md exclusion | Directly demonstrated | — |
| `test astro mini-astro absolute docs is route not missing asset` | Integration | Regression: absolute `/docs` not misclassified as missing asset | Directly demonstrated | — |
| `fixtures/mini-theme-astro` + determinism test | Integration | Theme-archaeology ledger shape, two-run byte-identity, source immutability | Directly demonstrated | All ledger decision categories proven |
| `fixtures/hostile-theme-astro` + test | Integration | Remote CSS, runtime signals, duplicates, traversal detection | Directly demonstrated | — |
| `test wordpress decode entities` | Unit | HTML entity decoding | Directly demonstrated | — |
| `test wordpress extractNamedElement CDATA` | Unit | CDATA extraction | Directly demonstrated | — |
| `fixtures/unit-wxr` | Integration | Per-field preservation matrix (posts, pages, statuses, excerpts, etc.) | Directly demonstrated | — |
| `fixtures/media-wxr` | Integration | Media materialization: copied, missing, ambiguous, traversal/absolute rejection | Directly demonstrated | — |
| `fixtures/adversarial-wxr` | Integration | Unicode, slug collisions, deep pages, duplicate media basenames | Directly demonstrated | Hostile WPTT (offline only) |
| `fixtures/hostile-asset-filenames` | Integration | Space/Unicode/percent/traversal/symlink/collision cases | Directly demonstrated | — |
| `fixtures/hostile-instagram` | Integration | Fence injection safety, media URI rejection | Directly demonstrated | — |
| `fixtures/fm-review-mixed`, `fm-review-no-unknown`, `fm-review-open-fence` | Integration | Frontmatter key audit, open-fence tolerance, all-clean case | Directly demonstrated | — |
| `fixtures/dogfood-starlight` | Integration | Starlight ~60-page selection, asset migration, manifests | Directly demonstrated | Real-site smoke |
| `fixtures/hostile-starlight` | Integration | Hostile Starlight signals | Directly demonstrated | — |
| `fixtures/takeout-intake` | Convention/planning | Intake contract structure | Documented (README + manifest) | No automated test |
| Instagram in-module tests | Unit | Currently leak under testing allocator (noted in main.zig) | Partial (excluded from `refAllDecls`) | Allocation safety |
| Cross-platform CI | — | — | Uncertain | Not evidenced |
| Byte-identical repeated-run for WordPress | — | — | Uncertain | No explicit two-run comparison test in evidence |
| Allocation-failure coverage | — | — | Not demonstrated | All modes |
| Permission-denied `--out` | — | — | Not demonstrated | — |


***
