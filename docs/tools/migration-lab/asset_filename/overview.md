---
title: "`tools/migration-lab/asset_filename.zig` overview"
id: docs/tools/migration-lab/asset_filename
status: draft
tags: [boris, zig, tools, migration-lab, asset_filename]
---

# `tools/migration-lab/asset_filename.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/asset_filename/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/asset_filename/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/asset_filename/review-state|Review state]]

## Executive summary

`tools/migration-lab/asset_filename.zig` is the self-contained implementation module for the `--mode=asset-filename` operating mode of the `boris-migration-lab` standalone binary. It is not an entry point with a `main` function; instead it exports a `pub fn run(io, allocator, options)` callable that is dispatched from `tools/migration-lab/main.zig` when the CLI selects the `asset-filename` (or alias `assets` / `asset-compat` / `filename-compat`) mode.

The developer workflow it supports is one-way import preparation: real Astro and Starlight content trees routinely carry asset filenames containing spaces, Unicode codepoints, and percent-encoded forms such as `%20`. The Boris product compiler enforces a strict path grammar — `[A-Za-z0-9._-]+` per segment under sibling `{page-stem}.assets/` trees — and rejects anything outside it by design. This module bridges that gap as an offline, read-only sanitization pass: it discovers every Markdown page and its sibling `.assets/` subtree, classifies each within-tree path against the Boris grammar, sanitizes unsafe names segment-by-segment (URL-decoding `%XX` first, then collapsing unsafe characters to dashes), copies the resulting assets into the configured output directory, and rewrites Markdown image and link destinations to point to the sanitized paths.

The file exists separately from the Boris product compiler for a clear design reason stated in both the module header and the README: product path validation is a deliberate fail-closed boundary for publish correctness, incremental cleanup, and portable URLs. Sanitizing migration archives is a one-way import concern with provenance, not a justification for widening the runtime contract. The module therefore mirrors the Boris path grammar locally (the comment `// mirrors Boris core; do not import src/` appears at the grammar section) rather than importing any `src/` compiler module.

This file is the complete implementation of the asset-filename mode. It does not delegate to other lab-specific submodules; the only shared dependency is `std` (Zig standard library). The entry point `main.zig` handles CLI parsing and dispatches `asset_filename.run(...)` with a resolved `Options` struct; all discovery, sanitization, collision detection, manifest serialization, and output publication happen inside this file.

Inputs are the content tree under `--root` (or its `content/` subdirectory when present) plus the sibling `.assets/` directories adjacent to each discovered Markdown page. The module reads those files byte-for-byte without interpretation; it does not evaluate Markdown AST, execute MDX, call external processes, or access the network. Outputs, written exclusively under `--out`, are: a sanitized `content/` tree with rewritten Markdown files and renamed asset files; `asset_filename_manifest.json` (per-asset inventory with action, reason, and SHA-256); `rewrite_manifest.json` (per-rewrite Markdown destination record); and `report.json` / `REPORT.md` (counts and policy summary). All paths in manifests use `/`-separated content-root-relative representation.

Determinism is documented as a contract and demonstrated by dedicated fixture tests that run the tool twice on the same input and compare `asset_filename_manifest.json` byte-for-byte across runs. Collision safety (both exact-path and ASCII-case-fold) is documented and directly tested with the `hostile-asset-filenames` fixture. Symlink rejection is implemented via `isSymlink()` and documented in safety rule 10, but direct symlink-handling tests are not separately visible in the evidence reviewed. The module never deletes, renames, or modifies any source file.

What this file and tool do not prove: universal correctness across all Markdown reference syntaxes; safe handling of every adversarial filename on every host filesystem; cross-platform byte-identical output (path separators and filesystem ordering); allocation-failure safety under all conditions; or that a sanitized output is semantically correct input for the Boris product compiler without further human review.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module (migration laboratory) |
| Conceptual domain | One-way asset filename sanitization for Boris content-local asset grammar compatibility |
| Tool family | `boris-migration-lab` — standalone migration laboratory |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Module; compiled into `zig-out/bin/boris-migration-lab` |
| Product runtime dependency | None — not linked into the `boris` product binary |
| Root build integration | Not included in root `build.zig` or root `zig build test`; exposed only through `tools/migration-lab/build.zig` |
| Expected execution commands | `zig build run -- --mode=asset-filename --root=<dir> --out=<dir>` (from `tools/migration-lab/`); `zig build --build-file tools/migration-lab/build.zig run -- --mode=asset-filename ...` (from repo root) |
| Input authority | Markdown pages and sibling `.assets/` trees under `--root` or `--root/content`; read-only |
| Output ownership | All writes under `--out`; source tree is never modified |
| Network or subprocess use | None — no network access, no subprocess invocation |
| Main collaborators | `tools/migration-lab/main.zig` (dispatch site); `std` only |
| Documentation depth warranted | Medium — complete standalone implementation module with documented safety contract |


***

## Role in the Boris architecture

This file is a module within the `tools/migration-lab/` standalone tool package. It is:

- **Not linked into production**: The `boris` product binary is built from `src/`; `tools/migration-lab/` is a separate Zig package with its own `build.zig` and is explicitly excluded from the root `zig build test` gate.
- **Compiled as part of a separate executable**: `zig build` inside `tools/migration-lab/` produces `zig-out/bin/boris-migration-lab`. This file is compiled into that binary as the implementation module for one operating mode.
- **Not imported by another tool**: No other tool or product module imports this file.
- **Not used only as a test root**: It exports `pub fn run` plus several public helper functions (`isBorisSafeWithinTree`, `sanitizeSegment`, `sanitizeWithinTree`, `urlDecodeAlloc`, `unsafeReason`, `joinNormalized`) that are tested inline.

Relative to the broader architecture:


| Subsystem | Relationship |
| :-- | :-- |
| `boris` product binary | Completely separate; no shared compilation unit |
| Root `build.zig` | Not referenced |
| `tools/migration-lab/build.zig` | Compiled into the lab binary |
| `tools/migration-lab/main.zig` | Dispatch site; calls `asset_filename.run(...)` |
| Boris source content RAG | Not an input; not an output |
| Context Bundles | Not involved |
| Boris product content compiler | Does not import `src/`; mirrors path grammar locally |
| Boris HTML publication / JSON IR | Not involved |
| Generated `source-rag/` output | Not involved |
| Migration laboratory (other modes) | Sibling modes in the same binary; no shared state |
| LLM / review workflows | Generated manifests may be consumed as review evidence; not a normative source |

The module does not describe the source-RAG corpus and is not part of any product content pipeline.

***

## Tool boundary and non-goals

**Implemented boundaries (enforced in code):**

- The module never writes to any path outside the configured `out_dir`. The `refuseOutputInsideSource` function checks that `out_dir` is not equal to, not a prefix of, and not a suffix of `source_dir`, returning `error.OutputInsideSource` before any filesystem access.
- The module never modifies any file under the source tree. All reads use `readFileAlloc`; no write calls target the source directory.
- The module never imports `src/` compiler modules. The comment `// mirrors Boris core; do not import src/` appears at the path-grammar section. The Boris path grammar (`[A-Za-z0-9._-]+` per segment) is re-implemented locally in `isBorisSafeWithinTree` and `isSafeChar`.
- The module never invokes subprocesses or opens network connections. Only `std` filesystem and crypto APIs are used.
- The module never silently overwrites a destination with different bytes. The `run` function and asset-copy helpers check for destination existence before writing and return `error.Collision` when an existing file differs.
- The module never follows symlinks from the source tree. `isSymlink()` (using `dir.readLink`) is called before any source file is opened; symlinked assets produce a `rejected` record with `reason: "symlink"`.
- The module never relaxes Boris path grammar. Already-safe paths are left unchanged with `action: "unchanged"`; no exceptions are made.
- The module never fetches remote assets, runs JavaScript, or evaluates MDX.

**Documented intentions without separately tested mechanical enforcement:**

- The README safety rule 10 states that destination collisions are rejected (no silent overwrite). This is implemented in code, but comprehensive collision coverage across all edge cases (race conditions, case-collision on case-insensitive filesystems) depends on caller discipline and host filesystem behavior.
- The module is documented as not a migration tool for the Boris product compiler's own path contract — it is an import tool. The product compiler is not invoked and its grammar is not changed.

**Explicit non-goals (documented):**

- Does not evaluate documentation correctness.
- Does not perform semantic interpretation of Markdown content.
- Does not invoke an LLM.
- Does not upload data.
- Does not act as a Boris content compiler.
- Is not part of the ordinary `boris build` execution path.
- Does not act as a general Markdown renderer or MDX migration tool.

***

## Build and invocation model

`asset_filename.zig` has no standalone `build.zig` of its own. It is compiled as a Zig module imported by `tools/migration-lab/main.zig`, which is the root source of the `boris-migration-lab` executable declared in `tools/migration-lab/build.zig`.

**Build declarations (from README and build structure):**

- `zig build` from `tools/migration-lab/` compiles `zig-out/bin/boris-migration-lab`.
- `zig build test` from `tools/migration-lab/` runs all inline tests in the lab, including those in this file.
- From the repo root, both steps are available as `zig build --build-file tools/migration-lab/build.zig` and `zig build --build-file tools/migration-lab/build.zig test`.
- Root `zig build` and root `zig build test` do not include this tool.

**Imported modules:** `std` only. No `src/` imports.

**Build options:** None specific to this module; `quiet` mode is passed at runtime via `Options`.

**Default working directory assumption:** The build step and `zig build run` must be run from `tools/migration-lab/` when using relative fixture paths; the tool itself resolves all paths from the given `--root` and `--out` arguments.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Compile `boris-migration-lab` binary | `tools/migration-lab/*.zig` | `zig-out/bin/boris-migration-lab` | Also available as `zig build --build-file tools/migration-lab/build.zig` from repo root |
| `zig build test` (from `tools/migration-lab/`) | Run all inline tests including asset-filename tests | Lab source + fixtures | Pass/fail | Includes hostile and determinism fixture runs |
| `zig build run -- --mode=asset-filename --root=<dir> --out=<dir>` | Run asset-filename sanitization | Content tree under `--root` | Sanitized content + manifests under `--out` | Aliases: `assets`, `asset-compat`, `filename-compat` |
| `zig-out/bin/boris-migration-lab --mode=asset-filename --root=<dir> --out=<dir>` | Direct binary invocation | Same as above | Same as above | Must be built first |


***
