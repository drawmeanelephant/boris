---
title: "`tools/migration-lab/starlight.zig` overview"
id: docs/tools/migration-lab/starlight
status: draft
tags: [boris, zig, tools, migration-lab, starlight]
---

# `tools/migration-lab/starlight.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/starlight/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/starlight/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/starlight/review-state|Review state]]

## Executive summary

`tools/migration-lab/starlight.zig` is the Starlight-mode conversion module of the `boris-migration-lab` standalone developer tool. It is not the entry point for the executable; that role belongs to `tools/migration-lab/main.zig`, which dispatches to `starlight.run()` when invoked with `--mode starlight`. The file is a large, self-contained implementation module—by far the largest single source file in the migration-lab package at 224,560 bytes—and contains the full logic for read-only preflight conversion of an Astro/Starlight content tree into a Boris candidate Markdown tree.[^1_2][^1_1]

The module supports the developer workflow of migrating an existing Starlight-shaped documentation site into Boris. It discovers the content root (supporting both the locale-directory shape `src/content/docs/<locale>/` and the root-locale default-language shape), selects candidate pages deterministically up to a configured `--max-pages` cap, strips untrusted agent/directive/instruction/prompt fences from MDX bodies, neutralizes dynamic JSX asset attribute expressions, rewrites proven internal Markdown links and relative image paths, migrates proven local Markdown images into Boris page-sibling `stem.assets` trees under `--out`, and emits a suite of sidecar JSON manifests and human-readable reports. Source trees are never modified.[^1_4][^1_2]

The tool exists separately from the Boris product compiler for deliberate architectural reasons. It operates on untrusted, arbitrary third-party Markdown and MDX content that may contain adversarial frontmatter, embedded directives, JSX components, and non-Boris link shapes. Coupling this surface into the product compiler would widen the product's trust boundary, introduce Node/Astro runtime dependencies, and pollute the clean IR pipeline with migration-specific heuristics. The lab is explicitly scoped as a preflight conversion aid—it produces review evidence and candidate content, not normative Boris IR or HTML. It does not import any module from `src/`, has its own standalone `build.zig` and `build.zig.zon`, and is excluded from the root `zig build test` gate.[^1_3][^1_4]

The file is the complete implementation for the Starlight mode; it is not merely a thin entry point. It contains all data structures, discovery, filtering, frontmatter parsing, MDX transformation, link rewriting, asset migration, entity collision resolution, relation-candidate extraction, manifest serialization, and test fixtures for this mode. The `run()` public function is the only entry point consumed by `main.zig`. Testing is done via inline Zig `test` blocks within this file and companion fixture directories; several tests perform two-run byte-identity checks on real fixture trees, including a 67-page dogfood fixture and a hostile adversarial fixture.[^1_2][^1_4]

The tool writes exclusively under the caller-supplied `--out` directory. It does not access the network, does not invoke subprocesses (except optionally invoking a Boris binary for compile verification when `--boris` is supplied), and does not use any library beyond the Zig standard library. No random identifiers or timestamps are embedded in the generated body content, and path ordering is lexicographic; these properties together support the byte-identity determinism claimed by tests. However, the claim of cross-platform byte-identity is not tested beyond the CI host; platform separator behavior and filesystem enumeration order are residual uncertainties.[^1_4][^1_2]

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | Migration preflight / content archaeology |
| Tool family | `boris-migration-lab` (standalone) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Module imported as `starlight` by `main.zig`; executable is `boris-migration-lab` |
| Product runtime dependency | No — not linked into `boris` product binary; does not import `src/` |
| Root build integration | Excluded from root `zig build test`; accessible only through `tools/migration-lab/build.zig` |
| Expected execution commands | `zig build run -- --mode starlight --root <dir> --out <dir>` from `tools/migration-lab/` |
| Input authority | Read-only access to Starlight project root; source files are never modified |
| Output ownership | All writes under `--out`; source root is not written |
| Network or subprocess use | No network; optional Boris subprocess for compile verification when `--boris` is supplied |
| Main collaborators | `main.zig` (dispatcher), fixture directories under `tools/migration-lab/fixtures/` |
| Documentation depth warranted | High — largest module in the package; covers conversion logic, manifests, safety boundaries |


***

## Role in the Boris architecture

`tools/migration-lab/starlight.zig` is entirely outside the Boris product binary and its ordinary execution path. It is compiled only as part of the `boris-migration-lab` standalone executable, which is built from `tools/migration-lab/build.zig`. The root `build.zig` does not include this tool as a step or dependency; it is explicitly isolated.[^1_3][^1_4]

Within the migration-lab package, this file is imported by `main.zig` as `const starlight = @import("starlight.zig")` alongside the other mode modules (`archaeology`, `wordpress`, `instagram`, `obsidian`, `notion`, `filed`, `assetfilename`, `themearchaeology`, `themematerialize`, `wordpresstheme`, `linkaudit`, `frontmatterreview`). The `main` function calls `starlight.run(io, gpa, opts)` when the mode is `.starlight`. This file is not imported by any other module.[^1_3]

The outputs written by this module—`content/*.md`, `routemap.json`, `selectionmanifest.json`, `unsupportedmanifest.json`, `assetsmanifest.json`, `navflatten.json`, `provenancemanifest.json`, `linkreview.json`, `headingfragments.json`, `boundarymanifest.json`, `compilereport.json`, `relationcandidates.json`, `report.json`, `REPORT.md`—are candidate material for human review and optional Boris compilation. They are not part of the product content RAG, Context Bundles, or normal HTML publication pipeline. They are generated and disposable; they are not tracked as authoritative documentation.[^1_4]

The module is not a migration tool for the Boris source itself; it is a migration tool for third-party Starlight-shaped content trees. It does not interact with the Boris IR, the Boris JSON output, the documentation observatory, or any Context Bundle construction. Its relationship to Context Bundles is zero: it produces candidate Markdown, not packaged documentation artifacts.[^1_4]

The module is:

- Not linked into production.
- Compiled as part of the `boris-migration-lab` separate executable.
- Not imported by any other tool module.
- Not used as a test root by the root build.
- Not exposed through any root build convenience step.

***

## Tool boundary and non-goals

`tools/migration-lab/starlight.zig` is explicitly bounded as a preflight content converter and evidence emitter. All boundaries described below are drawn from inspected source and README evidence.[^1_2][^1_4]

**What the tool is allowed to inspect:** The Starlight project root at the caller-supplied `--root` path, read-only. This includes `.mdx` and `.md` files under `src/content/docs/`, the `public/` directory for absolute image resolution, and `astro.config.*` files (text-scan only, no evaluation).[^1_2][^1_4]

**What it is allowed to write:** Only files under the caller-supplied `--out` directory. It writes converted Markdown pages under `--out/content/`, page-sibling asset files under `--out/content/<entity>.assets/`, and all sidecar JSON manifests and reports.[^1_4]

**Tracked source file modification:** None. The module contains a test (`starlight F-L1 image-path fixture migrates, preserves, and fails closed`) that explicitly reads the source fixture after a run and asserts byte-identity with the pre-run snapshot, mechanically verifying source immutability.[^1_2]

**Compiler behavior:** Unchanged. The module does not alter Boris compilation behavior, IR, or product frontmatter.

**Product frontmatter/IR:** The module emits only closed Boris frontmatter (`id`, `title`, `parent`, `status`, `tags`) in generated Markdown. Source frontmatter keys are inventoried and surfaced in `provenancemanifest.json` and `unsupportedmanifest.json`; they are not carried into the output grammar.

**Semantic interpretation:** Limited and explicit. The module performs mechanical mapping (Starlight admonitions → Boris `&lt;Aside>`, `&lt;TabItem>` → `&lt;Details>`, `&lt;Card>` → card syntax, `&lt;Steps>` wrapper stripped). Ambiguous or non-mappable constructs become `manualreview` boundary items. No invented semantic transforms are performed.

**Documentation correctness:** Not evaluated. The tool performs mechanical packaging, not documentation review.

**LLM invocation:** None.

**Data upload:** None.

**Network access:** None. This is documented in the README safety rules and structurally consistent with the Zig standard-library-only dependency model.

**Migration tool scope:** Yes, this file is a migration tool, but only for Starlight → Boris candidate conversion. It is not a migration tool for Boris's own source or for any other format.

**Ordinary `boris` execution path:** Completely separate. The module does not appear on the Boris compilation or publishing path.

The boundary between implemented enforcement and documented intention: source immutability and no-network access are mechanically enforced by the implementation (no write calls to the source directory, no network API in Zig stdlib invoked). The absence of LLM invocation and subprocess use (apart from the optional Boris binary) is structurally enforced.

***

## Build and invocation model

The module has no standalone build of its own. It is a Zig module imported by `main.zig` and compiled as part of the `boris-migration-lab` executable defined in `tools/migration-lab/build.zig`.[^1_3][^1_4]

**Build declarations:** `tools/migration-lab/build.zig` declares the `boris-migration-lab` executable with `main.zig` as its root. The `starlight.zig` module is reachable via the `@import("starlight.zig")` chain from `main.zig`. Tests are declared in a separate test artifact that includes inline `test` blocks from all mode modules.[^1_3]

**Root build integration:** None. The root `build.zig` does not reference `tools/migration-lab/`. The README explicitly states: "Root `zig build` deliberately covers only the product compiler and does not include this standalone laboratory."[^1_4]

**Test artifacts:** Inline `test` blocks in `starlight.zig` are covered by `zig build test` from within `tools/migration-lab/`. These tests use `std.testing.allocator` and `std.testing.io` and operate on committed fixture directories.[^1_2]

**Target and optimization:** Not specified separately for this module; uses the defaults of the `boris-migration-lab` executable build step.

**Imported modules:** Only `std` (Zig standard library). No external dependencies, no product `src/` imports.

**Build options:** None specific to `starlight.zig`. Mode selection is done at runtime via `--mode starlight`.

**Default working directory assumptions:** The invocation commands in the README assume execution from `tools/migration-lab/`. When invoked from the repo root, the `--build-file tools/migration-lab/build.zig` flag is required.


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Compile `boris-migration-lab` executable | `main.zig` and all imported modules including `starlight.zig` | `zig-out/bin/boris-migration-lab` | Standalone; no root build involvement |
| `zig build test` (from `tools/migration-lab/`) | Run all inline tests including starlight tests | Source + fixture directories | Pass/fail on stdout | Covers multi-run byte-identity checks |
| `zig build run -- --mode starlight --root <dir> --out <dir>` | Execute Starlight conversion | Starlight project root | Candidate tree + manifests under `--out` | `--max-pages`, `--locale`, `--boris` are optional |
| `zig build --build-file tools/migration-lab/build.zig` (from repo root) | Same as above from repo root | Same | Same | Explicit build file path required |
| `zig build --build-file tools/migration-lab/build.zig test` | Run tests from repo root | Same | Pass/fail | Targeted aggregate gate |


***
