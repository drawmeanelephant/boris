---
title: "`tools/migration-lab/archaeology.zig` overview"
id: docs/tools/migration-lab/archaeology
status: draft
tags: [boris, zig, tools, migration-lab, archaeology]
---

# `tools/migration-lab/archaeology.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/archaeology/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/archaeology/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/archaeology/review-state|Review state]]

## Executive summary

`tools/migration-lab/archaeology.zig` is the read-only Astro-mode implementation module for the `boris-migration-lab` standalone developer tool. It does not contain a `main` function; it is imported by `tools/migration-lab/main.zig`, which serves as the single executable entry point for all migration-lab modes. The module's module-level comment states its purpose precisely: "Read-only Astro Boris migration archaeology core. Walks an Astro project/export tree, classifies sources, and builds deterministic report structures. Never mutates scan-root files."

The module supports the developer workflow of bringing an existing Astro or Astro/Starlight project into Boris. A developer runs `zig build run -- --mode astro --root <project> --out <reportdir>` from within `tools/migration-lab/`. The module then performs a filesystem walk of the Astro tree, classifies every discovered file into one of eight `FileKind` values (content page, page route, layout, component, public asset, src asset, config, other), extracts frontmatter metadata, resolves links and stitch relationships between content and routing layers, detects hazards (non-Boris frontmatter keys, layouts, nested YAML, block scalars, JSX tags), and emits a pair of machine-readable and human-readable reports (`report.json`, `REPORT.md`) into the output directory. Input source files are never written, renamed, or stat-mutated.

The module is entirely distinct from the Boris product compiler. It does not appear in the root `build.zig`, does not share compilation units with the product binary, and has no runtime dependency relationship with Boris's content pipeline, JSON IR, HTML emission, or Context Bundle mechanisms. Its outputs are developer artifacts — evidence reports used by the author to plan and perform the migration — not content fed directly into the Boris compilation pipeline.

`archaeology.zig` is a substantial implementation module, not merely a thin entry point. It contains the complete Astro-mode data model (`InventoryEntry`, `FrontmatterLite`, `LinkRef`, `Hazard`, `Stitch`, `ProposedId`, `ParentChild`, `BrokenLink`, `SlugConflict`, `AssetEntry`, `MissingAsset`, `HumanReview`, `Report`), the full suite of path-classification predicates (`isContentPage`, `isPageRoute`, `isLayout`, `isComponent`, `isPublicAsset`, `isSrcAsset`, `isConfig`, `classifyPath`), entity ID and slug derivation functions (`proposeEntityId`, `slugFromContentPath`), frontmatter parsing (`parseFrontmatterLite`), link extraction (`extractLinks`), hazard collection (`collectHazards`), stitch resolution, absolute-link routing (`absoluteToRouteKey`, `absoluteToPublicPath`), and the top-level `run` function that orchestrates the full scan-and-emit cycle.

Test coverage is meaningful and exercised in-process. The `main.zig` test block directly invokes `archaeology.run` against committed synthetic fixtures (`fixtures/mini-astro`, `fixtures/root-content-astro`, `fixtures/absolute-links-astro`, `fixtures/dual-content-roots-astro`, `fixtures/adversarial-astro`) and verifies output structure, report field presence, source-file immutability, and byte-identical determinism across two sequential runs. The determinism tests run two passes against the same fixture and call `std.testing.expectEqualStrings` on `report.json` and `REPORT.md`, providing directly demonstrated evidence of reproducibility for those fixtures on the same host. Cross-platform byte identity is not demonstrated.

What the file does not prove: it does not validate all possible Astro config layouts, does not handle i18n prefix routing, does not resolve TypeScript import aliases, does not identify dynamic-route disambiguation beyond single-slug matching, and does not claim universal Astro compatibility. These are documented non-goals in both the README and the in-source `Documented limitations` section of the Astro mode.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer tool — implementation module (Astro archaeology mode) |
| Conceptual domain | Pre-migration analysis; Astro-to-Boris source archaeology |
| Tool family | `boris-migration-lab` — standalone migration laboratory |
| Build root | `tools/migration-lab/build.zig` (standalone; not root `build.zig`) |
| Executable or module name | Not directly; compiled into `zig-out/bin/boris-migration-lab` via `main.zig` |
| Product runtime dependency | None — not linked into the Boris product binary |
| Root build integration | Absent; root `zig build test` deliberately excludes this tool |
| Expected execution commands | `zig build run -- --mode astro --root <dir> --out <outdir>` (from `tools/migration-lab/`) |
| Input authority | Astro project tree (read-only); profile set by `--root` and `--mode astro` |
| Output ownership | Output directory nominated via `--out`; never inside scan root |
| Network or subprocess use | None (documented and structurally consistent with implementation) |
| Main collaborators | `main.zig` (imports and dispatches), fixture directories, `docs/MIGRATION.md` |
| Documentation depth warranted | High — this is the core Astro-mode model and discovery engine |

## Role in the Boris architecture

`archaeology.zig` sits entirely outside the Boris product compiler pipeline. The Boris product binary (`zig-out/bin/boris`) reads source content, compiles JSON IR, emits HTML, and manages Context Bundles. None of those systems import, call, or depend on anything in `tools/migration-lab/`. The root `build.zig` does not reference `tools/migration-lab/` at all. The README explicitly states: "Root `zig build test` deliberately covers only the product compiler and does not include this standalone laboratory."

Within the migration-lab itself, `archaeology.zig` occupies the role of implementation module for Astro mode. `main.zig` imports it (`const archaeology = @import("archaeology.zig")`) and dispatches to `archaeology.run(io, gpa, .{…})` when the selected mode is `.astro`. Other modules in the same directory (`wordpress.zig`, `instagram.zig`, `obsidian.zig`, `notion.zig`, `starlight.zig`, `themearchaeology.zig`, etc.) are peer modules covering other source formats; they do not import `archaeology.zig`.

The module reads Boris source files — specifically `docs/contracts/frontmatter.md` defines the closed author grammar (`id`, `title`, `parent`, `status`, `tags`) which is encoded directly as the `boriskeys` constant in `archaeology.zig`. The module uses this to classify frontmatter keys as Boris-safe or as migration hazards. It does not call into the Boris compiler, does not read Boris config, and does not produce any artifact that the Boris compiler directly consumes as input.

Generated outputs (`report.json`, `REPORT.md`) are developer-facing migration planning documents. They are not product content RAG sources, not Context Bundles, not part of normal HTML publication, and not JSON IR. They inform the author about what exists in the Astro tree and what must be done before running `boris` on the migrated content.

The file is:

- Not linked into the Boris production binary
- Compiled as part of the standalone `boris-migration-lab` executable via `main.zig`
- Not imported by any other migration-lab mode module
- Not used as a test root directly (tests live in `main.zig` and exercise `archaeology.run`)
- Exposed through the `tools/migration-lab/build.zig` `run` step only

## Tool boundary and non-goals

The boundary between `archaeology.zig` and the Boris product is structurally enforced by separate compilation. The module has no `@import` path that reaches into the Boris compiler source tree. It shares only the Zig standard library with the product binary.

**What the tool is allowed to inspect:** Any file reachable by a recursive directory walk of `--root`, subject to the skip-dir list (`.git`, `.hg`, `.svn`, `node_modules`, `.astro`, `dist`, `.vercel`, `.netlify`, `.output`, `zig-out`, `.zig-cache`, `zig-cache`) and skip-file list (`.DS_Store`, `Thumbs.db`).

**What it is allowed to write:** Only the nominated `--out` directory, which must differ from `--root`. This is enforced at the `main.zig` dispatch level: `if (std.mem.eql(u8, opts.rootdir, opts.outdir)) … return ExitCode.usage.int()`. No check within `archaeology.zig` itself prevents writing to a path that is a sibling of but distinct from the scan root; the containment guard lives in `main.zig`.

**Does it modify tracked source files?** No. Source immutability is directly demonstrated by tests in `main.zig` that read a fixture file before and after calling `archaeology.run` and call `std.testing.expectEqualStrings(before, after)`.

**Does it change compiler behavior?** No.

**Does it change product frontmatter or IR?** No.

**Does it perform semantic interpretation?** It classifies files by path pattern and extension, parses YAML frontmatter using a best-effort line scanner (not a full YAML parser), and extracts Markdown links with a heuristic scanner. It does not evaluate Astro config, does not run MDX, and does not resolve TypeScript aliases. These are documented non-goals.

**Does it evaluate documentation correctness?** No. It flags keys outside the closed Boris grammar and structural hazards, but does not make semantic judgments about content quality.

**Does it invoke an LLM?** No.

**Does it upload data?** No.

**Does it access the network?** No. The README states explicitly: "There is no network access, no zip extraction, no scraping, and no product compiler coupling."

**Does it act as a migration tool?** For Astro mode, archaeology.zig is read-only: it produces reports only and does not write any Markdown content. The content-writing modes (wordpress, instagram, obsidian, notion, starlight, filed) are in peer modules.

**Is it part of the ordinary `boris` execution path?** No.

The implemented boundary (separate compilation, no shared imports, no product binary linkage) is mechanically enforced. The "never mutates source" contract is mechanically verified by tests.

## Build and invocation model

`archaeology.zig` has no standalone `build.zig` of its own. It is compiled as part of the single `boris-migration-lab` executable defined in `tools/migration-lab/build.zig`. The root `build.zig` does not reference the migration-lab at all.

From `tools/migration-lab/`:

```
zig build            # builds boris-migration-lab binary
zig build test       # compiles and runs all inline tests
zig build run -- … # builds and runs with supplied arguments
```

From the repository root:

```
zig build --build-file tools/migration-lab/build.zig
zig build --build-file tools/migration-lab/build.zig test
zig build --build-file tools/migration-lab/build.zig run -- --mode astro …
```

The executable name is `boris-migration-lab` (output at `zig-out/bin/boris-migration-lab` within the `tools/migration-lab/` build tree). The module itself does not appear in any root build step or test step.


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Compile `boris-migration-lab` | All `.zig` sources under `tools/migration-lab/` | `zig-out/bin/boris-migration-lab` | Standalone; root build not involved |
| `zig build test` (from `tools/migration-lab/`) | Run all inline tests | Source + fixture directories | Pass/fail | Exercises `archaeology.run` via `main.zig` tests |
| `zig build run -- --mode astro --root DIR --out DIR` | Run Astro archaeology | Astro project tree | `report.json`, `REPORT.md` in `--out` | `--out` must differ from `--root` |
| `zig build --build-file tools/migration-lab/build.zig run -- …` | Same from repo root | Same | Same | Useful in CI or from top-level scripts |

No generated artifacts from `archaeology.zig` are prerequisites for subsequent build steps.
