---
title: "`tools/migration-lab/build.zig` overview"
id: docs/tools/migration-lab/build
status: draft
tags: [boris, zig, tools, migration-lab, build]
---

# `tools/migration-lab/build.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/build/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/build/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/build/review-state|Review state]]

## Executive summary

`tools/migration-lab/build.zig` is the standalone Zig build script for the `boris-migration-lab` developer tool. It lives entirely within `tools/migration-lab/` and is not part of the Boris product binary or the root `build.zig` build graph. Its sole purpose is to declare the `boris-migration-lab` executable, its library modules, a `run` convenience step, and the tool's test binary — all scoped to the standalone `tools/migration-lab/` package.

The migration lab is a multi-mode developer tool that assists authors in migrating content from external platforms (Astro, WordPress WXR, Instagram, Obsidian, Notion, Filed.fyi, Starlight, asset-filename sanitization, theme archaeology, theme materialization, WordPress PHP theme archaeology, link audit, and frontmatter review) into Boris-compatible Markdown. The build file declares the single top-level executable whose entry point is `tools/migration-lab/main.zig`; all mode-specific logic is delegated to peer Zig source modules imported by `main.zig`. The file is described in the catalog at 1,238 bytes, making it a compact build script rather than a logic-bearing file.

The lab exists separately from the Boris product compiler because migration work involves inspecting and transforming untrusted foreign source trees that neither compile nor validate against Boris's content grammar. Running this code inside the product compiler would pollute the compiler's deterministic, read-only publication path with external format parsers, WordPress XML decoding, Instagram JSON normalization, and optional subprocess spawning for Starlight compile verification. Separating it also means root `zig build` and root CI never execute migration code unless explicitly requested.

The build file is the complete standalone build declaration for the tool. It is not an entry point for logic. Its direct collaborators are `main.zig` (executable root), the thirteen peer mode modules (`archaeology.zig`, `wordpress.zig`, `instagram.zig`, `obsidian.zig`, `notion.zig`, `filed.zig`, `starlight.zig`, `assetfilename.zig`, `themearchaeology.zig`, `themematerialize.zig`, `wordpresstheme.zig`, `linkaudit.zig`, `frontmatterreview.zig`), and optionally a `build.zig.zon` package manifest. The tool is invoked via `zig build run -- <args>` from inside `tools/migration-lab/`, or via `zig build --build-file tools/migration-lab/build.zig` from the repository root. Both invocation paths produce the same executable at `zig-out/bin/boris-migration-lab`.

No test infrastructure is declared in the build file that is inaccessible via `zig build test`. All mode-specific fixture tests and unit tests are pulled into the single test binary through `main.zig`'s inline `test` blocks and `@import`-aggregated test declarations. The tool does not access the network, does not involve generated prerequisites, and relies only on the Zig standard library. Build options beyond the standard Zig target/optimization pair are not evident from the available catalog entry size or README. Generated output directories (`zig-out/`, temporary report directories) are not build prerequisites.

The build file's contribution to confidence is structural: it cleanly separates the tool's compilation from the product, ensures `zig build test` runs the full fixture suite within the tool's own package, and enables the README's documented invocation commands. What it does not prove is cross-platform byte identity of outputs, absence of resource exhaustion on large inputs, or allocation-failure coverage in tool modes.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Standalone tool build script |
| Conceptual domain | Developer tooling / migration laboratory |
| Tool family | `boris-migration-lab` multi-mode content migration |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | `boris-migration-lab` |
| Product runtime dependency | None — not linked into `boris` product binary |
| Root build integration | Not included in root `build.zig`; invoked via `--build-file` from repo root |
| Expected execution commands | `zig build`, `zig build run -- <args>`, `zig build test` from `tools/migration-lab/` |
| Input authority | Peer Zig modules under `tools/migration-lab/`; fixture directories under `tools/migration-lab/fixtures/` |
| Output ownership | `zig-out/bin/boris-migration-lab`; per-run report directories under caller-specified `--out` |
| Network or subprocess use | No network in build; Starlight mode optionally spawns `boris` subprocess at runtime |
| Main collaborators | `main.zig`; thirteen mode modules; `build.zig.zon` (if present) |
| Documentation depth warranted | Moderate — file is small; depth comes from its declared modules and integration evidence |


***

## Role in the Boris architecture

`tools/migration-lab/build.zig` sits entirely outside the Boris product runtime. The root `build.zig` does not include it, and root `zig build` or root `zig build test` will not compile or exercise it. It is relevant only when a developer or author explicitly runs `zig build` or `zig build --build-file tools/migration-lab/build.zig` (the latter from the repository root).

The file occupies the bottom of the dependency chain for the migration lab: it is the Zig build root that wires `main.zig` into an executable, declares mode modules as separate Zig modules (or as source files compiled into the same executable), attaches a `run` step, and exposes the test binary. Its relationship to the rest of the Boris architecture is one of deliberate isolation:

- It is **not** linked into the `boris` product binary.
- It is **compiled as a separate executable** (`boris-migration-lab`).
- It is **not imported** by any other tool or library.
- It is **not used as a test root** for the product compiler.
- It is **exposed** as a convenience build via `zig build --build-file tools/migration-lab/build.zig` from the repository root, as documented in the README.

The lab reads Boris product source files (specifically, it may locate `layouts/main.html` as a repo-root probe in `starlight.zig` when `--boris` is not passed), but this is a runtime filesystem walk, not a compile-time dependency. The lab writes only to the caller-specified `--out` directory and never to tracked source files. Its outputs — `report.json`, `REPORT.md`, manifest JSONs, converted Markdown trees — are migration artifacts consumed by human authors, not by the Boris compiler pipeline.

The tool is conceptually separate from:

- the Boris product content RAG;
- normal HTML publication;
- JSON IR output;
- Context Bundles;
- the `source-rag` tool;
- the Boris compiler runtime path;
- generated site pages.

***

## Tool boundary and non-goals

The `build.zig` file itself enforces boundary through build isolation. The broader tool boundary, which this file enables, is:

**What the tool is allowed to inspect:** Any filesystem path supplied by the caller via CLI flags (`--root`, `--wxr`, `--dump`, `--vault`, `--export`, `--filed-root`, `--ledger`, `--content`). Inspection is read-only: no source input is opened for writing. The `starlight` mode may probe for a `boris` binary and invoke it as a subprocess for compile verification, but this is guarded by binary discovery logic and only occurs when a `boris` binary is found.

**What it is allowed to write:** Only the directory supplied by `--out` (default: `migration-report`). Every mode enforces `--out` ≠ input root at the CLI layer, returning exit code 2 on violation. This is a documented contract enforced by implementation checks in `main.zig`'s mode dispatch.

**What it does not do (implemented boundaries):**

- Does not modify tracked source files. Source immutability is directly demonstrated by fixture tests (`test astro sources are never modified`, similar patterns in WordPress and adversarial fixtures).
- Does not change compiler behavior or product frontmatter/IR.
- Does not perform semantic interpretation of documentation content beyond pattern-matching foreign formats.
- Does not evaluate documentation correctness.
- Does not invoke an LLM.
- Does not upload data.
- Does not access the network (no HTTP client imports; documented in README and per-mode usage strings: "no network fetch," "no API," "no scraping," "no zip extraction").
- Does not act as a migration tool for Boris source content itself (it is a migration tool for external sources *into* Boris-ready Markdown, which authors then review).
- Is not part of the ordinary `boris` execution path.

**Documented intentions not mechanically verifiable from `build.zig` alone:** The no-network and read-only-source properties are documented as invariants in the README and per-mode usage text, and partially demonstrated by tests, but the absence of network calls is not structurally enforced at compile time (no HTTP library is linked, but this relies on the Zig standard library having no HTTP in the imported module set — uncertain without full module inspection).

***

## Build and invocation model

`tools/migration-lab/build.zig` is the standalone build root for the `boris-migration-lab` tool. Based on its catalog size (1,238 bytes), it is a compact file. Based on the README's documented invocation commands and the root-invocation pattern `zig build --build-file tools/migration-lab/build.zig`, it follows standard Zig 0.16 build idiom:

- Declares one `addExecutable` for `boris-migration-lab` with root source `main.zig`.
- Adds an `installArtifact` step so `zig build` places the binary at `zig-out/bin/boris-migration-lab`.
- Declares a `run` step via `addRunArtifact` so `zig build run -- <args>` passes trailing arguments to the binary.
- Declares a test step via `addTest` on `main.zig`, which aggregates inline tests and `@import`-based test inclusion.
- No build options (e.g., `addOption`) are evidenced beyond standard target/optimization handling.
- No generated artifacts are declared as prerequisites.
- No external package dependencies are declared by evidence available; the tool uses only the Zig standard library.

The executable name (`boris-migration-lab`) is established by the README and the tool's self-identifier in `main.zig`'s usage text (`boris-migration-lab [options]`).

**Module imports:** `main.zig` imports thirteen peer modules directly via `@import("archaeology.zig")` through `@import("frontmatterreview.zig")`. These are source-file-level imports within the same package directory, not separate build artifacts. They compile into the single `boris-migration-lab` executable.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Compile executable | `main.zig` and peer modules | `zig-out/bin/boris-migration-lab` | Standard install |
| `zig build run -- <args>` (from `tools/migration-lab/`) | Compile and run | As above + CLI args | Report tree under `--out` | Passes args after `--` to binary |
| `zig build test` (from `tools/migration-lab/`) | Run all tool tests | `main.zig` test blocks + fixture directories | Test pass/fail | Includes fixture I/O tests |
| `zig build --build-file tools/migration-lab/build.zig` (from repo root) | Compile from repo root | Same as above | `zig-out/bin/boris-migration-lab` | Documented in README; equivalent result |
| `zig build --build-file tools/migration-lab/build.zig test` (from repo root) | Test from repo root | Same as above | Test pass/fail | README-documented aggregate gate |
| `zig-out/bin/boris-migration-lab <args>` | Direct invocation | CLI args | Report tree under `--out` | After `zig build` install |


***
