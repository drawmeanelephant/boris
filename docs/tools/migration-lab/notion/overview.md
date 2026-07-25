---
title: "`tools/migration-lab/notion.zig` overview"
id: docs/tools/migration-lab/notion
status: draft
tags: [boris, zig, tools, migration-lab, notion]
---

# `tools/migration-lab/notion.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/notion/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/notion/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/notion/review-state|Review state]]

## Executive summary

`tools/migration-lab/notion.zig` is the Notion-mode implementation module of the Boris migration laboratory. It is not an entry point, a build root, or a product-compiler component — it is a single-mode implementation file imported by `tools/migration-lab/main.zig` and compiled exclusively as part of the `boris-migration-lab` standalone executable. Its public surface is the `run` function and a collection of pure-Zig helper types and utilities; all orchestration, CLI parsing, and process lifecycle are handled upstream by `main.zig`.

The file supports the developer workflow of converting an official, already-unpacked Notion Markdown+CSV export into a Boris-ready content tree. It discovers Markdown and MDX-like page files within the export directory, strips the 32-hex Notion page IDs embedded in folder and file names, maps the resulting cleaned paths to Boris entity IDs, rewrites unambiguous local page links and attachment references, copies local media bytes into a deterministic per-page output structure, and emits a machine-readable `report.json`, a human-readable `REPORT.md`, and a `mediamanifest.json` alongside the converted content. It never contacts the Notion API, performs no OAuth, does no network access of any kind, does not extract zip archives, and never modifies the export tree it reads from.

The tool exists separately from the Boris product compiler because content migration is a one-way import concern with its own provenance and review obligations. The product compiler operates on already-valid Boris content trees and must not carry the complexity of dirty third-party export formats, Notion-specific path conventions, link-rewriting heuristics, or conversion-class bookkeeping. The tool boundary is explicit: `notion.zig` contains no import of any `src/` product-compiler module and is not wired into root `build.zig` test steps or the product binary.

`notion.zig` is a substantial implementation file (~90 KB source), not a thin adapter. It contains the full directory-walk logic, Notion page-ID parsing, entity-ID sanitization and deduplication, frontmatter parsing and rewriting, body-link scanning, media-manifest construction, report emission, and inline unit tests. It delegates nothing to product modules; all shared utilities (path normalization, percent-decoding, frontmatter parsing, JSON escaping, SHA-256 hashing) are self-contained within the file or within the peer modules of `tools/migration-lab/`. The primary collaborators are `main.zig` (entry point and mode dispatch), `fixtures/mini-notion/` (unit and integration test fixtures), and the inline `test` blocks scattered through the file itself.

The executable is built via the standalone `tools/migration-lab/build.zig`; it is not part of `zig build` from the repository root. Tests are run via `zig build test` within the `tools/migration-lab/` directory and cover determinism (byte-identical repeated runs), structural field presence in `report.json`, parent inference, media copying, and source immutability. Some error paths (unreadable files, allocation failure, malformed CSV database paths) lack direct inline test coverage, making them uncertain. The tool does not prove semantic correctness of the migrated content — it produces a mechanically faithful candidate tree and a review queue; human follow-up is always expected.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module (not an entry point) |
| Conceptual domain | Content migration / archaeology |
| Tool family | `boris-migration-lab` |
| Build root | `tools/migration-lab/build.zig` (standalone) |
| Executable or module name | `boris-migration-lab` (via `main.zig`); module imported as `const notion = @import("notion.zig")` |
| Product runtime dependency | No — not linked into `boris` product binary |
| Root build integration | Not included in root `build.zig` test steps; invoked only via standalone build |
| Expected execution commands | `zig build run -- --mode notion --export <dir> --out <dir>` from `tools/migration-lab/`; `zig build --build-file tools/migration-lab/build.zig run -- --mode notion ...` from repo root |
| Input authority | Unpacked Notion Markdown+CSV export directory (read-only) |
| Output ownership | All writes under `--out` only; never modifies inputs |
| Network or subprocess use | None — no network, no subprocess invocation |
| Main collaborators | `main.zig` (caller), `fixtures/mini-notion/` (test fixtures), inline `test` blocks |
| Documentation depth warranted | High — substantial logic for entity-ID normalization, link rewriting, media materialization, and report construction |


***

## Role in the Boris architecture

`notion.zig` is exclusively a developer-tool module. It sits in the `tools/migration-lab/` subtree, which is architecturally separate from all Boris product subsystems (`src/`, `layouts/`, root `build.zig` test gates). It is never linked into the `boris` product binary.

Within `tools/migration-lab/`, `notion.zig` occupies the same position as `wordpress.zig`, `obsidian.zig`, `instagram.zig`, and others: it is a mode-specific implementation file compiled into `boris-migration-lab` and dispatched from `main.zig` via a `switch(opts.mode)` branch. The entry point calls `notion.run(io, gpa, .{ .exportdir = ..., .outdir = ..., .quiet = ... })` and maps any returned error to `ExitCode.ioerror`.

The tool is not related to and does not interact with:

- The Boris product content RAG (different corpus and pipeline)
- HTML publication or JSON IR output
- Context Bundles
- The source-RAG tool under `tools/source-rag/`
- Root `build.zig` test steps (root `zig build test` does not run migration-lab tests)

The generated outputs under `--out` are developer migration artifacts. They are inputs to a human review workflow: the operator inspects `report.json`, `REPORT.md`, and `mediamanifest.json`, then passes accepted content to Boris for normal publication. The outputs are not authoritative documentation and are not tracked as normative repository artifacts.

`notion.zig` is:

- **Not** linked into production
- **Not** a standalone entry point
- **Compiled** as part of the `boris-migration-lab` executable
- **Not** imported by any other tool module
- **Not** used as a test root on its own; tested via inline `test` blocks compiled by the standalone `zig build test`

***

## Tool boundary and non-goals

**What the tool is allowed to inspect:** The unpacked Notion export directory tree — Markdown/MDX page files, CSV database files, and local attachment/media files within that tree.

**What it is allowed to write:** Files exclusively under the configured `--out` directory. The `main.zig` dispatch enforces `--out != --export` before calling `run`. The tool creates content pages, a media subdirectory, and report/manifest files within that directory.

**Source immutability:** The export directory is never modified. The inline tests verify this directly by reading export-tree files before and after a run and asserting byte identity.

**Compiler behavior:** Unchanged. The tool has no influence on Boris compiler behavior, frontmatter grammar, IR, or publication.

**Product frontmatter / IR:** Not modified. The tool emits closed Boris frontmatter (`id`, `title`, `parent`, `status`, `tags`) in output Markdown files under `--out`. It does not rewrite any product source files.

**Semantic interpretation:** The tool does not evaluate Notion databases, execute Notion blocks, follow synced block references, or interpret Relation/Rollup fields. These produce hazard records in `report.json` and leave the original content raw.

**Documentation correctness:** Not evaluated. The tool performs mechanical path and link rewriting; it does not assess whether the migrated content is semantically correct Boris content.

**LLM invocation:** None.

**Upload / network:** None — explicitly documented and structurally consistent with the implementation (no `std.net`, no subprocess spawning).

**Migration tool classification:** Yes — this is exactly a migration tool. It is part of the migration laboratory, not the ordinary `boris` execution path.

**Implemented vs. documented boundaries:**

- No network and no source writes are structurally enforced (no socket or destructive filesystem API calls in the implementation).
- `--out != --export` guard is implemented in `main.zig` dispatch, not inside `notion.run` itself — the boundary is enforced by the caller.
- The `normalizeRelPath` and traversal-rejection logic provide path-containment within the export for link resolution, but output-root containment for write paths depends on the path-construction conventions in the implementation rather than a single enforced check.

***

## Build and invocation model

`notion.zig` has no standalone build file. It is compiled as a module of the `boris-migration-lab` executable defined in `tools/migration-lab/build.zig`. The root `build.zig` does not include this executable or its tests.

From within `tools/migration-lab/`:

- `zig build` → builds `boris-migration-lab` executable (includes `notion.zig`)
- `zig build test` → runs all inline `test` blocks across all mode modules, including those in `notion.zig`
- `zig build run -- --mode notion --export <dir> --out <dir>` → executes the tool in notion mode

From the repository root:

- `zig build --build-file tools/migration-lab/build.zig` → same as above
- `zig build --build-file tools/migration-lab/build.zig test` → runs migration-lab tests

No generated artifacts are prerequisites for building. No `build.zig.zon` dependency resolution is required beyond the Zig standard library.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build run -- --mode notion --export <dir> --out <dir>` | Run Notion migration | Unpacked Notion export dir | `content/`, `media/`, `report.json`, `REPORT.md`, `mediamanifest.json` under `--out` | Must be run from `tools/migration-lab/` |
| `zig build --build-file tools/migration-lab/build.zig run -- --mode notion --export <dir> --out <dir>` | Same from repo root | Same | Same | `--build-file` required |
| `zig build test` (from `tools/migration-lab/`) | Run all migration-lab tests | Fixtures under `fixtures/mini-notion/`, others | Test pass/fail | Covers inline `test` blocks in `notion.zig` |
| `zig build --build-file tools/migration-lab/build.zig test` | Same from repo root | Same | Same |  |


***
