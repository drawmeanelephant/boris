---
title: "`tools/migration-lab/filed.zig` overview"
id: docs/tools/migration-lab/filed
status: draft
tags: [boris, zig, tools, migration-lab, filed]
---

# `tools/migration-lab/filed.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/filed/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/filed/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/filed/review-state|Review state]]

## Executive summary

`tools/migration-lab/filed.zig` is a standalone migration-laboratory module — not a program entry point — that implements the complete Filed.fyi migration logic for the `boris-migration-lab` executable. It is imported by `tools/migration-lab/main.zig` as `const filed = @import("filed.zig")` and dispatched when the CLI mode is `.filed`. The file has no `main` function; its public surface is the `run` function, the `RunOptions` struct, a set of public schema constants (`format_id`, `schema_version`, `tool_version`), and the exported types needed by callers and tests.

The tool supports a single, narrowly bounded developer workflow: given a Filed.fyi Astro source root conforming to an observed two-collection layout (`src/content/docs/changelog` — exactly one record — and `src/content/docs/releases` — exactly three records), it reads those Markdown files, normalises any legacy `parentEntry`/`parententry` frontmatter keys to the canonical Boris `parent` key, strips embedded instruction-shaped blocks from each body, emits Boris-ready Markdown pages plus per-collection index stubs, and writes a provenance manifest and a human-readable report. The input tree is never modified.

The tool exists separately from the Boris product compiler because its task is pre-migration evidence analysis and reversible content conversion, not documentation compilation or site generation. It has no semantic understanding of the Boris IR, no dependency on any Boris product module, and no product-compiler import anywhere in the file. Its `run` function accepts a `RunOptions` value — a plain struct of path strings and a quiet flag — and otherwise depends only on `std.Io` and `std.mem.Allocator`.

The file is the complete implementation of the filed mode. It contains all discovery logic, frontmatter parsing, parent-key normalisation, body stripping, slug generation, output emission, manifest and report construction, and the inline Zig tests that exercise those behaviours. There is no separately compiled sub-module.

Compilation is governed entirely by `tools/migration-lab/build.zig`, which lists `main.zig` as the executable root module. `filed.zig` is compiled as part of that single root module, not as a separate build step or library. The root `build.zig` does not expose the migration lab at all; all build and test steps are invoked with `--build-file tools/migration-lab/build.zig`. The executable is named `boris-migration-lab` and lands in `zig-out/bin/`.

Inputs are the source Markdown files found under `src/content/docs/changelog/` and `src/content/docs/releases/` within the supplied source root. The tool performs no recursive filesystem walk beyond those two fixed subdirectories, does no network access, invokes no subprocesses, and neither reads nor writes anything outside the explicitly supplied output directory. All output goes to the `--out` path: per-record Markdown pages under `content/changelog/` and `content/releases/`, per-collection `index.md` stubs, a `provenancemanifest.json` (JSONL-style), and a `report.json`.

The cardinality constraint (`changelog == 1`, `releases == 3`) is enforced at runtime by `run`; a fixture that does not satisfy it causes `error.UnexpectedCollectionCardinality`. This constraint is verified by the inline fixture tests, which exercise the `mini-filed` fixture. Parent-key normalisation (`normalizeParentKeys`) is covered by two dedicated fixture suites (`filed-parent-normalize` and `filed-parent-conflict`), whose README files document the expected outcomes in detail. The `isSafeParentId` validation logic is tested inline. Body-stripping behaviour is tested for open-fence and mixed-content cases.

The file does not prove: output atomicity; cleanup of stale output on re-run; symlink safety in path traversal; cross-platform byte identity; byte-for-byte determinism across tool versions; allocation-failure recovery; or validity of its output under the Boris product compiler's closed-frontmatter grammar for any fixture other than those referenced by the existing tests.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool module (migration laboratory) |
| Conceptual domain | Content migration; frontmatter normalisation; provenance reporting |
| Tool family | `tools/migration-lab` — standalone migration laboratory |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Module compiled into `boris-migration-lab`; no separate executable |
| Product runtime dependency | **No** — no Boris product module is imported |
| Root build integration | **None** — root `build.zig` does not reference the migration lab |
| Expected execution commands | `zig build run -- --mode filed --filed-root <path> --out <dir>` (from `tools/migration-lab`) |
| Input authority | Filed.fyi Astro source root, read-only |
| Output ownership | Caller-supplied `--out` directory; tool creates it if absent |
| Network or subprocess use | **None** — structurally: no `std.process`, no socket, no HTTP client |
| Main collaborators | `tools/migration-lab/main.zig` (importer and dispatcher), inline fixture tests |
| Documentation depth warranted | Medium — complete implementation in one file; deep coverage of parent-key normalisation and body stripping warranted |


***

## Role in the Boris architecture

`filed.zig` is a module within the `tools/migration-lab` standalone tool. It is **not** linked into the `boris` product binary; the product compiler has no import of this file or of any migration-lab module. The root `build.zig` does not expose a migration-lab build step; all invocation is through the lab's own `build.zig`.

Within the migration lab, `filed.zig` is one of thirteen mode modules (`archaeology`, `wordpress`, `instagram`, `obsidian`, `notion`, `filed`, `starlight`, `assetfilename`, `themearchaeology`, `themematerialize`, `wordpresstheme`, `linkaudit`, `frontmatterreview`), all of which are compiled together into the single `boris-migration-lab` executable via `main.zig`. The file is not imported by any other migration-lab module.

The tool's output is an independent, reversible content slice for human review. It is **not** product content RAG, not a Context Bundle, not part of the Boris documentation observatory, and not a source-RAG pack. Downstream LLM or review workflows may read the emitted Markdown and provenance manifest as migration evidence, but the output carries no normative authority over the Boris product.

The separation is structural: `filed.zig` imports only `std`, uses `std.Io` for all filesystem I/O, and performs no schema validation against Boris IR types. Its format identifier (`boris-filed-fyi-migration-lab`) and schema version (`2`) exist solely within the migration lab's own output contracts.

***

## Tool boundary and non-goals

**What the tool is allowed to inspect:** Markdown and MDX files directly under `src/content/docs/changelog/` and `src/content/docs/releases/` in the supplied source root. No other paths are read.

**What it is allowed to write:** Files under the caller-supplied output directory. The `run` function enforces that `outdir` is not equal to `sourcerootdir` and is not a path-prefix child of it; this check is structural (string comparison), not based on filesystem resolution.

**What it does not do (structurally confirmed):**

- Does not modify any tracked source file
- Does not import any Boris product module
- Does not change compiler behaviour, product frontmatter grammar, or IR
- Does not perform semantic interpretation of document content
- Does not evaluate documentation correctness
- Does not invoke an LLM
- Does not upload data
- Does not access the network
- Does not invoke subprocesses
- Is not part of the ordinary `boris` execution path

**What it does do:** It performs parent-key *syntactic* normalisation — rewriting `parentEntry`/`parententry` to `parent` in generated output — and body stripping of instruction-shaped fences. These are mechanical text transformations, not semantic migrations. The `isSafeParentId` local validator mirrors the Boris entity-id shape rules but is a local copy; it is not imported from the product compiler.

**Implemented versus documented boundaries:** The read-only constraint on source is structurally enforced (the source root is opened read-only; `run` never calls a write function on the source `Io.Dir`). The output-containment check is a string comparison and is not symlink-aware. The cardinality constraint is runtime-enforced. The "no network" property is structurally enforced by the absence of any network API import.

***

## Build and invocation model

`filed.zig` is compiled as part of the `boris-migration-lab` executable root module (`main.zig`). There is no separate build step or library target for `filed.zig` alone.

**`tools/migration-lab/build.zig`** declares:

```zig
const root_mod = b.createModule(.{
    .root_source_file = b.path("main.zig"),
    .target = target,
    .optimize = optimize,
});
const exe = b.addExecutable(.{
    .name = "boris-migration-lab",
    .root_module = root_mod,
});
```

The test step compiles the same root module via `b.addTest(.{ .root_module = root_mod })` and sets its working directory to the package directory (`b.path(".")`), which is required for fixture-relative paths used in inline tests.

There is no `tools/migration-lab/build.zig.zon` evidence available in the source pack; this is marked uncertain. There are no build options (`b.option`) declared in the build file — target and optimize use standard defaults.

No generated artifacts are prerequisites for compilation or testing.


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab`) | Build executable | `main.zig` and all imported modules | `zig-out/bin/boris-migration-lab` | Standard optimize/target defaults |
| `zig build test` (from `tools/migration-lab`) | Run all inline tests | Same root module; fixtures under `tools/migration-lab/fixtures/` | Test pass/fail | CWD set to package dir |
| `zig build run -- --mode filed --filed-root <path> --out <dir>` | Run filed migration | Source root, output dir | Content pages, index stubs, manifests, report | Mode implied by `--filed-root` |
| `zig build --build-file tools/migration-lab/build.zig` (from repo root) | Build from repo root | Same | Same | Root `build.zig` does not expose this step |
| `zig-out/bin/boris-migration-lab --mode filed --filed-root <path> --out <dir>` | Direct invocation | Same | Same | Equivalent to `zig build run --` path |


***
