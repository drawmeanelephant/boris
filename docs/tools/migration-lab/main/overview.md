---
title: "`tools/migration-lab/main.zig` overview"
id: docs/tools/migration-lab/main
status: draft
tags: [boris, zig, tools, migration-lab, main]
---

# `tools/migration-lab/main.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/main/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/main/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/main/review-state|Review state]]

## Executive summary

`tools/migration-lab/main.zig` is the sole entry point and CLI dispatcher for `boris-migration-lab`, a standalone developer tool that converts or audits content from external platforms (Astro, WordPress, Instagram, Obsidian, Notion, Filed.fyi, Starlight, and others) into Boris-compatible Markdown, reports, and sidecar manifests. It is compiled as a separate executable entirely outside the Boris product compiler pipeline. Nothing in this file is linked into the `boris` product binary; it shares no compilation unit, no runtime path, and no build target with the product.

The file is primarily a thin entry point: it owns `main`, the `Mode` enum, the `Options` struct, `parseOptions`, `printUsage`, the `ExitCode` enum, and the top-level `switch` dispatch to one subordinate module per mode. The substantive implementation of each migration mode is delegated entirely to imported modules (`archaeology.zig`, `wordpress.zig`, `instagram.zig`, `obsidian.zig`, `notion.zig`, `filed.zig`, `starlight.zig`, `assetfilename.zig`, `themearchaeology.zig`, `themematerialize.zig`, `wordpresstheme.zig`, `linkaudit.zig`, `frontmatterreview.zig`). The entry point's role is therefore: parse and validate CLI arguments, guard against accidental output–input collisions, and delegate to the correct `run(io, gpa, opts)` function.

The tool is invoked via `zig build run -- <args>` from `tools/migration-lab/` or through the root `build.zig` convenience step (exact step name requires further inspection of root `build.zig`, which was not directly read; the source-RAG INDEX lists the tool's build file as `tools/migration-lab/build.zig`). Every mode writes only into the configured `--out` directory, which is mechanically required to differ from every named input path—the check is performed in `main` before any delegated `run` call. No mode contacts the network, executes subprocesses (except `starlight` mode's optional Boris compile verification pass, which is in `starlight.zig` and guarded by an optional `--boris` flag), reads tracked Boris source files as product inputs, or modifies the Boris compiler's behavior.

The tool has substantial test coverage in `main.zig` itself: `parseOptions` is covered by one test per mode covering both fused (`--flag=value`) and split (`--flag value`) forms, plus alias resolution, defaults, and error cases. Fixture integration tests for the `astro` mode directly demonstrate two-run byte-identical output (determinism), input immutability, adversarial corpus handling, link classification, route-key correctness, dual-content-root behavior, and absolute-link disambiguation. Coverage for other modes (obsidian, notion, filed, starlight, asset-filename, theme-archaeology, theme-materialize, wordpress-theme, frontmatter-review) is pulled in via a `test` block referencing those modules; the `instagram` module is explicitly excluded from `refAllDecls` in this file's test block because its in-module tests currently leak under the testing allocator. The `wordpress` mode has unit tests for HTML entity decoding and `extractNamedElement` but no integration fixture test visible in this file. Cross-platform byte identity is not tested or structurally proven.

The file does not prove: that output paths are free of traversal; that all modes are byte-identical across platforms; that the tool is safe to run on an untrusted repository without operator scrutiny; or that any mode's JSON schema is stable across tool versions.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Standalone developer-tool entry point |
| Conceptual domain | Migration archaeology / content adaptation |
| Tool family | `tools/migration-lab` (separate from `tools/source-rag`) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | `boris-migration-lab` |
| Product runtime dependency | None — not linked into the `boris` product binary |
| Root build integration | Present (exact step name uncertain; root `build.zig` not directly inspected) |
| Expected execution commands | `zig build run -- --mode&lt;MODE> [flags]` from `tools/migration-lab/`; `zig build test` for tests |
| Input authority | External platform source trees, WXR XML files, dump directories — never Boris product source |
| Output ownership | Configured `--out` directory only; mechanically refused to overlap any named input |
| Network or subprocess use | No network. One subprocess: optional Boris compile-verification in `starlight` mode (`starlight.zig`, guarded by `--boris` flag) |
| Main collaborators | `archaeology.zig`, `wordpress.zig`, `instagram.zig`, `obsidian.zig`, `notion.zig`, `filed.zig`, `starlight.zig`, `assetfilename.zig`, `themearchaeology.zig`, `themematerialize.zig`, `wordpresstheme.zig`, `linkaudit.zig`, `frontmatterreview.zig` |
| Documentation depth warranted | High — 13 modes, rich test surface, complex CLI, active development |


***

## Role in the Boris architecture

`tools/migration-lab/main.zig` exists entirely outside the Boris product runtime. The Boris product binary compiles source Markdown with Boris frontmatter into HTML and JSON IR; `boris-migration-lab` reads foreign-platform content (Astro projects, WordPress WXR exports, Instagram Takeout dumps, Obsidian vaults, Notion exports, Filed.fyi Astro roots, Starlight trees, theme files, generated HTML output for link auditing, and content trees for frontmatter review) and writes Boris-compatible Markdown candidate files, sidecar JSON manifests, and human-readable reports. Its output is **not** consumed by the Boris product compiler during an ordinary `boris` run — it is migration scaffold material that a developer reviews and then deliberately commits to the Boris content tree.

Relative to the root `build.zig`: the tool has its own `tools/migration-lab/build.zig`. Whether root `build.zig` exposes a convenience step is uncertain (root build not directly inspected). The tool is not part of product HTML publication, not part of JSON IR output, not part of Context Bundles, and not related to `tools/source-rag`. It is one of several `tools/` sibling directories.

The `starlight` mode is the only mode that can optionally spawn a subprocess — it may invoke the Boris binary for compile verification of converted output, but only when `--boris <path>` is explicitly provided, and this behavior lives in `starlight.zig`, not in `main.zig`.

The tool:

- **Is not** linked into production.
- **Is** compiled as a separate executable (`boris-migration-lab`).
- **Is not** imported by another tool.
- **Is not** used only as a test root.
- **May be** exposed through a root build convenience step (uncertain).

***

## Tool boundary and non-goals

**Implemented boundaries (mechanically enforced):**

- `main` checks `std.mem.eql(u8, <input>, opts.outdir)` for every mode-specific input path before any `run` call. If any input path equals the output directory, it returns `ExitCode.usage` without calling the mode's `run`. This is a string equality check, not a canonical-path or realpath check — it does not prevent containment or symlink overlap.
- No mode in `main.zig` opens a network socket, resolves DNS, or uses `std.http`. The only subprocess invocation is in `starlight.zig` behind an explicit flag.
- No mode writes to tracked Boris source files. The `astro` mode's "sources are never modified" property is directly demonstrated by a test.

**Documented intentions (not mechanically enforced in this file):**

- The tool comment states "Never rewrites inputs." Each mode's `run` function is responsible for its own read-only discipline; `main.zig` enforces only the output–input directory equality check.
- "No semantic interpretation" — the tool produces review artifacts (JSON, Markdown) without claiming correctness of generated content. This is a design intent, not an enforced invariant.

**What the tool does not do:**

- Does not modify Boris frontmatter in tracked files.
- Does not affect Boris compiler behavior or product IR.
- Does not evaluate documentation correctness.
- Does not invoke an LLM.
- Does not upload data.
- Does not act as a migration tool in the product pipeline — it is a scaffold generator for human-driven migration.
- Is not part of the ordinary `boris` execution path.

***

## Build and invocation model

The tool's build root is `tools/migration-lab/build.zig`. The file declares a standalone Zig executable named `boris-migration-lab` whose root module is `tools/migration-lab/main.zig`. Each mode's implementation module is imported by name from sibling `.zig` files in the same directory.

Root build integration: uncertain. The source bundle's INDEX lists `tools/migration-lab/build.zig` (1,238 bytes) as a tracked file, suggesting a small dedicated build file. Root `build.zig` was not directly inspected for step names.

Test artifacts: declared as a `zig build test` step in `tools/migration-lab/build.zig`. The test binary pulls in module tests for obsidian, notion, filed, starlight, asset-filename, theme-archaeology, theme-materialize, wordpress-theme, and frontmatter-review. Instagram module tests are explicitly excluded from `refAllDecls` in `main.zig`'s test block.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build run -- --mode astro --root <dir> --out <dir>` | Astro archaeology report | Astro project tree | `report.json`, `REPORT.md` | Default mode; `--root` defaults to `.` |
| `zig build run -- --mode wordpress --wxr <file> [--media <dir>] --out <dir>` | WordPress WXR conversion | WXR XML file, optional media dir | `content/*.md`, `report.json`, `REPORT.md`, `mediamanifest.json` | `--wxr` implies `--mode wordpress` |
| `zig build run -- --mode instagram --dump <dir> --out <dir>` | Instagram Takeout conversion | Unpacked dump root | `content/*.md`, `theme/`, `report.json`, `REPORT.md`, `mediamanifest.json` | `--dump` implies `--mode instagram` |
| `zig build run -- --mode obsidian --vault <dir> --out <dir>` | Obsidian vault conversion | Vault root | `content/*.md`, `assets/`, `report.json`, `REPORT.md`, `attachmentsmanifest.json` | `--vault` implies `--mode obsidian` |
| `zig build run -- --mode notion --export <dir> --out <dir>` | Notion Markdown+CSV export conversion | Unpacked export root | `content/*.md`, `media/`, `report.json`, `REPORT.md`, `mediamanifest.json` | `--export` implies `--mode notion` |
| `zig build run -- --filed-root <dir> --out <dir>` | Filed.fyi changelog+releases slice | Filed.fyi Astro root | `content/changelog/`, `content/releases/`, `provenancemanifest.json`, `report.json`, `REPORT.md` | `--filed-root` implies `--mode filed` |
| `zig build run -- --mode starlight --root <dir> --out <dir> [--locale en] [--max-pages N] [--boris <path>]` | Starlight docs conversion | Starlight project root | Route map, manifests, converted pages, compile report | `en` locale only; subprocess iff `--boris` given |
| `zig build run -- --mode asset-filename --root <dir> --out <dir>` | Asset filename sanitization | Content tree | `assetfilenamemanifest.json`, `rewritemanifest.json`, `report.json`, `REPORT.md` | Aliases: `assets`, `asset-compat`, `filename-compat` |
| `zig build run -- --mode theme-archaeology --root <dir> --out <dir>` | AstroStarlight theme inventory | Theme project root | `adaptationledger.json`, `report.json`, `REPORT.md`, `BOUNDARY.md` | Read-only; no JS/MDX execution |
| `zig build run -- --mode theme-materialize --root <dir> --ledger <file> --out <dir>` | Ledger-driven theme draft | Ledger JSON + theme source tree | `theme/`, `materialize-manifest.json`, `MATERIALIZE-REPORT.md`, `PROVENANCE.md` | Requires prior `theme-archaeology` ledger |
| `zig build run -- --mode wordpress-theme --root <dir> --out <dir>` | Classic WordPress theme inventory | Theme root | `inventory.json`, `slotmapping.json`, `manualreview.json`, `prototypemain.html`, `report.json`, `REPORT.md` | PHP never executed |
| `zig build run -- --mode link-audit --root <dir> --out <dir>` | Generated HTML output link audit | Generated HTML tree | `linkaudit.json`, `REPORT.md` | External/mailto/tel/data/hash-only links not audited |
| `zig build run -- --mode frontmatter-review --content <dir> --out <dir>` | Frontmatter key audit | Content tree | `frontmatterreview.json`, `FRONTMATTERREVIEW.md` | Reports keys outside Boris closed grammar |
| `zig build test` | Run all test suites | Fixture directories | Test pass/fail | Instagram excluded from `refAllDecls` |
| `zig build --build-file tools/migration-lab/build.zig` | Build from repo root | Source | `zig-out/bin/boris-migration-lab` | Root-relative invocation |


***
