---
title: "`tools/migration-lab/obsidian.zig` overview"
id: docs/tools/migration-lab/obsidian
status: draft
tags: [boris, zig, tools, migration-lab, obsidian]
---

# `tools/migration-lab/obsidian.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/obsidian/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/obsidian/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/obsidian/review-state|Review state]]

## Executive summary

`tools/migration-lab/obsidian.zig` is the implementation module for the **obsidian migration mode** of the `boris-migration-lab` standalone developer tool. It is not an entry point; `tools/migration-lab/main.zig` is the process entry point, and it delegates to `obsidian.zig` via `obsidian.run(io, gpa, …)` when `--mode obsidian` (or the aliases `obs`, `vault`) is selected or when `--vault &lt;DIR>` is provided on the CLI. The file is compiled as part of a single executable (`zig-out/bin/boris-migration-lab`) under its own standalone build (`tools/migration-lab/build.zig`). It is not included in the root `build.zig` or its default test gate.

The module supports the **Obsidian vault → Boris Markdown** one-way migration workflow. Given a local Obsidian vault directory (`--vault`), it: walks the vault deterministically; classifies every vault item as a `.md` page, local attachment, `.canvas` file, or other; maps vault-relative `.md` paths to Boris entity IDs (spaces → `-`, case-preserved); resolves wiki-link targets using a ten-rule ordered resolution chain; rewrites unambiguous `&#91;&#91;Note]]` and `&#91;&#91;Note|alias&#93;&#93;` links to Boris entity IDs; rewrites unambiguous `!&#91;&#91;asset&#93;&#93;` embeds to Markdown image or link syntax; copies local attachments into the output `assets/` tree with a deterministic manifest; and emits `report.json`, `REPORT.md`, and `attachmentsmanifest.json`. It never reads or modifies the vault source tree.

The tool exists separately from the Boris product compiler because migration is an one-time, lossy, potentially destructive transformation concern. The product compiler must stay fail-closed on path grammar and frontmatter schema; migration concerns (wiki link resolution, Obsidian-specific attachment paths, plugin syntax inventory) are orthogonal and must not widen the product runtime contract. The separation is structural: `obsidian.zig` contains no imports of any `src/` Boris compiler module, and `tools/migration-lab/build.zig` is a standalone build file not referenced by the root `build.zig`.

This file is the **complete phase-1 implementation** for the obsidian mode, not merely an adapter shim. It contains: vault discovery, entity-ID derivation, collision disambiguation, wiki-link scanning (`scanWikiHits`), body rewriting (`rewriteBody`), frontmatter parsing (`parseFrontmatter`), Boris frontmatter emission (`buildFrontmatter`), provenance comment emission, attachment copy and manifest, report JSON serialization, report Markdown emission, and all inline unit and fixture tests. Its declared schema identifier is `boris-obsidian-migration-lab`, schema version `1`, tool version `0.1.1`.

The module is covered by inline unit tests (`pathToEntityId`, `sanitizeEntityId`, `pathSuffixMatch`, `isPluginTemplateWikiTarget`, `scanWikiHits`) and by the fixture-level integration tests declared in `main.zig` under `test "obsidian"`. Those integration tests exercise the `fixtures/mini-obsidian` vault, verify byte-for-byte determinism across two runs, confirm source immutability, check attachment copy and manifest fields, check report JSON schema keys, and verify that skip directories (`.obsidian`, `node_modules`) do not appear in output. What the tests do not demonstrate directly: path traversal rejection within vault paths, symlink behavior, failure behavior on unreadable vault files, or exhaustive link-resolution edge cases beyond those present in the mini-obsidian fixture.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer tool implementation module |
| Conceptual domain | Content migration / Obsidian vault archaeology |
| Tool family | `boris-migration-lab` multi-mode migration laboratory |
| Build root | `tools/migration-lab/build.zig` (standalone, not root `build.zig`) |
| Executable or module name | `boris-migration-lab` (shared with all migration-lab modes) |
| Product runtime dependency | None — no `src/` compiler imports |
| Root build integration | Not included; root `build.zig` does not reference `tools/migration-lab/` |
| Expected execution commands | `zig build run -- --vault &lt;DIR> --out &lt;DIR>` from `tools/migration-lab/`; or `zig build --build-file tools/migration-lab/build.zig run -- …` from repo root |
| Input authority | Caller-supplied `--vault &lt;DIR>` (local filesystem path; never modified) |
| Output ownership | All writes under caller-supplied `--out &lt;DIR>`; vault is read-only |
| Network or subprocess use | None structurally present in this module; not demonstrated in tests |
| Main collaborators | `main.zig` (entry, CLI dispatch), `std.Io` (I/O abstraction) |
| Documentation depth warranted | High — primary implementation module for a named migration mode |

## Role in the Boris architecture

`obsidian.zig` sits entirely outside the Boris product compiler pipeline. The file is:

- **Not linked into production.** The root `build.zig` does not reference `tools/migration-lab/` or its modules.
- **Compiled as part of a separate executable** (`boris-migration-lab`) under `tools/migration-lab/build.zig`.
- **Not imported by any other tool.** It is imported only by `main.zig` via `const obsidian = @import("obsidian.zig");`.
- **Not a test root.** Tests within the file (`test "pathToEntityId"`, `test "scanWikiHits"`, etc.) are compiled into the single `boris-migration-lab` test binary. Additional fixture integration tests are declared in `main.zig` under `test "obsidian notion filed starlight …"`.
- **Exposed through one convenience build step:** `zig build run -- --mode obsidian …` from `tools/migration-lab/` using the `run` step defined in `tools/migration-lab/build.zig`.

Relative to the Boris architecture:

- **Boris product binary:** unrelated; no shared compilation unit.
- **Root `build.zig`:** does not include this tool; root `zig build test` does not exercise it.
- **Standalone `tools/migration-lab/` build:** this file is one module of the monolithic `boris-migration-lab` executable.
- **Boris source files and contracts used as inputs:** none at runtime. The tool targets the closed Boris frontmatter grammar (`id`, `title`, `parent`, `status`, `tags`) as documented in `docs/contracts/frontmatter.md`, but it does not import that contract at compile time.
- **Generated `source-rag/` output:** unrelated. The obsidian module's output is a content migration artifact under `--out`, not a source-RAG pack.
- **Product content RAG:** unrelated.
- **Context Bundles:** unrelated.
- **LLM or review workflows:** the emitted `report.json`, `REPORT.md`, and `attachmentsmanifest.json` are intended as human-review artifacts for an author performing a one-way vault migration. They are not consumed by any automated Boris pipeline step.

The obsidian module does not generate Boris HTML, JSON IR, source-RAG packs, Context Bundles, or product release artifacts.

## Tool boundary and non-goals

**Implemented boundaries (structurally enforced or demonstrated by tests):**

- The vault path (`vaultdir`) and the output path (`outdir`) must differ. `main.zig` enforces this before calling `obsidian.run` and returns `ExitCode.usage` if they are equal. The test `"astro sources are never modified"` pattern is replicated for obsidian in the fixture test: the vault file `Notes/Alpha.md` is read before and after `run`, and `expectEqualStrings(before, after)` is asserted.
- The module never imports any module from `src/` (Boris compiler). This is structurally enforced by the absence of any such import statement.
- The module does not invoke the network. No `std.net` or HTTP client usage appears anywhere in the module.
- The module does not invoke subprocesses. No `std.process.Child` or equivalent appears.
- Skip directories (`.obsidian`, `.git`, `node_modules`, `dist`, `.output`, `zig-out`, `.zig-cache`, `zig-cache`) are tested: the fixture test asserts `node_modules` and `.obsidian` do not appear in `report.json`.
- Canvas files are inventoried as `unsupported` with a fixed detail string; they are never converted.
- Dataview, plugin syntax (Templater `&#123;&#123;…&#125;&#125;` targets), heading/block references, and unresolved/ambiguous wiki links are never silently dropped — they are retained raw and listed under `humanreview`.

**Documented intentions not independently tested in accessible evidence:**

- Symlink handling: the README states symlinks are not followed. This is not mechanically enforced by a rejection test in the available evidence.
- Attachment copy failure: entries where `copyok = false` are added to `humanreview` and `attachmentsmanifest` with `copied: false`. The failure path is structurally present in the code but no fixture specifically triggers a copy failure.
- Path traversal within vault paths: the module derives output paths from vault-relative paths. The available evidence does not include a hostile-obsidian fixture exercising traversal names (unlike `fixtures/hostile-asset-filenames` for the asset-filename mode).

**Non-goals (documented):**

- Dataview/DataviewJS evaluation or live queries.
- Canvas conversion.
- Plugin behavior (Tasks, Templater, etc.).
- Heading or block-reference rewriting (`Note^block`, `Note#Heading`).
- Silent discard of unresolved or ambiguous links.
- Product compiler contract changes.
- Network fetch, API access, zip extraction, or scraping.

## Build and invocation model

`obsidian.zig` has no standalone build file of its own. It is compiled as a module of the `boris-migration-lab` executable defined in `tools/migration-lab/build.zig`.

**Standalone build (`tools/migration-lab/build.zig`):**

```zig
const root_mod = b.createModule(.{
    .root_source_file = b.path("main.zig"),
    ...
});
const exe = b.addExecutable(.{
    .name = "boris-migration-lab",
    .root_module = root_mod,
});
```

The executable is built with `b.standardTargetOptions` and `b.standardOptimizeOption`, so target and optimization are caller-controlled. There are no build options (`b.option`) declared for the obsidian mode specifically. The test binary uses the same root module as the executable.

**Import chain:** `main.zig` → `const obsidian = @import("obsidian.zig");` → `obsidian.run(io, gpa, …)`.

**No generated artifact prerequisites.** The build has no pre-build steps; vault files are read at runtime, not compile time.

**Multiple build paths to the same executable:**

- From `tools/migration-lab/`: `zig build` → `zig-out/bin/boris-migration-lab`
- From repo root: `zig build --build-file tools/migration-lab/build.zig` → same artifact

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Build the `boris-migration-lab` binary | `main.zig` + all mode modules | `zig-out/bin/boris-migration-lab` | Standard target/optimize flags apply |
| `zig build run -- --vault &lt;DIR> --out &lt;DIR>` | Run obsidian mode | Vault directory | Content + assets + reports under `--out` | `--vault` implies `--mode obsidian` |
| `zig build test` (from `tools/migration-lab/`) | Run all unit and fixture tests | Source + `fixtures/` | Test pass/fail | Obsidian tests declared in `main.zig` and `obsidian.zig` |
| `zig build --build-file tools/migration-lab/build.zig run -- --mode obsidian --vault &lt;DIR> --out &lt;DIR>` | Run from repo root | Vault directory | Content + reports under `--out` | Equivalent to above |
| `zig-out/bin/boris-migration-lab --vault &lt;DIR> --out &lt;DIR>` | Direct binary invocation | Vault directory | Content + reports under `--out` | After `zig build install` |
