---
title: "`tools/migration-lab/wordpress.zig` overview"
id: docs/tools/migration-lab/wordpress
status: draft
tags: [boris, zig, tools, migration-lab, wordpress]
---

# `tools/migration-lab/wordpress.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/wordpress/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/wordpress/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/wordpress/review-state|Review state]]

## Executive summary

`tools/migration-lab/wordpress.zig` is the core implementation module for the WordPress WXR-to-Boris migration mode of the `boris-migration-lab` standalone developer tool. It is not an entry point; `main.zig` imports it as `@import("wordpress.zig")` and invokes its single exported `run` function, passing pre-parsed CLI options from the dispatcher. This file contains virtually the entire WordPress migration logic: XML parsing of the WXR export, content body conversion, media matching and materialization, report and manifest construction, and deterministic output publication. It is the largest single source file in the codebase at ~185 KB.

The module supports one developer workflow: taking an offline WordPress WXR export—plus an optional local copy of the site's media uploads directory—and producing a Boris-ready Markdown content tree, a JSON machine report, a media manifest, and a human-readable REPORT.md. Every output is written to a configured `--out` directory. No network requests are made, no PHP is executed, no archive extraction is performed, and no input file is ever modified. The tool is entirely read-only on its inputs.

The file exists as a separate module—rather than part of the Boris product compiler—because it encodes WordPress-specific domain knowledge (WXR schema, WP status codes, WP taxonomy conventions, WP permalink conventions, comment/trackback/pingback handling) that is irrelevant to and would contaminate the Boris compilation pipeline. It shares no modules with the product compiler and is not linked into the `boris` binary.

`wordpress.zig` is not a thin entry point. It contains: a WXR XML pull-parser, slug sanitization and entity-ID synthesis, body conversion with shortcode and Gutenberg block preservation, media reference harvesting (`src=`, `srcset`, `data-src`), media matching against a local uploads tree (with symlink rejection and duplicate-basename detection), page-local `stem.assets/` materialization, link resolution against the WXR item corpus, parent-child hierarchy mapping with Boris one-hop constraint enforcement, status mapping (draft/future/private/password-protected), feature-code accumulation, comment/trackback/pingback preservation in separate Markdown files, unsupported post-type preservation, trunk-stub generation, stale-output cleanup (deterministic wipe of `content/` and report sidecars on re-run), and full JSON and Markdown report emission. This is not a thin wrapper.

The tool carries deterministic guarantees over discovery order, entity-ID assignment, output path construction, and all report array sort orders—all enforced via explicit `std.mem.sort` calls with lexicographic comparators over owned slices. There are no timestamps in output frontmatter. Absolute paths and platform separators are not embedded in output. The `--out` guard (enforced in `main.zig` before dispatch) prevents the output directory from equalling the WXR path or the media directory.

Test coverage exists through inline Zig tests within the module (unit-wxr fixture, mini-wxr fixture) and through a broader coverage matrix documented in `fixtures/unit-wxr/README.md`. Tests exercise: slug synthesis, duplicate-slug disambiguation, status mapping, excerpt preservation, sticky-post reporting, empty-slug handling, empty-title fallback, parent–child hierarchy, deep hierarchy flagging, comment/trackback/pingback preservation, attachment inventory, menu-item preservation, media-present copying, media-missing reporting, and trunk-stub generation. Cross-platform byte identity is not mechanically demonstrated by CI evidence available in this pack. Whether the test runner performs allocator-leak checks is uncertain from available evidence.

The module does not prove: semantic correctness of the resulting Boris content; that all WordPress body constructs render correctly in the Boris HTML pipeline; that every valid WXR variant is handled; that very large exports do not exhaust memory; or that media copying is atomic (a failure mid-copy leaves a partial file; no staging-then-rename strategy is in evidence).

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | WordPress WXR migration, content archaeology |
| Tool family | `boris-migration-lab` (standalone, `tools/migration-lab/`) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Compiled as part of `boris-migration-lab`; not an independent executable |
| Product runtime dependency | None — not linked into `boris` product binary |
| Root build integration | Not included in root `zig build` or root `zig build test`; accessed only via `--build-file tools/migration-lab/build.zig` |
| Expected execution commands | `zig build run -- --wxr <path/to/export.xml> [--media <uploads-dir>] --out <outdir>` |
| Input authority | WXR XML file (required); local media directory (optional); both read-only |
| Output ownership | `<outdir>/content/`, `<outdir>/report.json`, `<outdir>/REPORT.md`, `<outdir>/mediamanifest.json` |
| Network or subprocess use | None — no network access, no subprocess invocation |
| Main collaborators | `main.zig` (dispatcher), `fixtures/mini-wxr/`, `fixtures/unit-wxr/`, `fixtures/media-wxr/` |
| Documentation depth warranted | High — largest module in the tool; complex domain logic |


***

## Role in the Boris architecture

`wordpress.zig` sits entirely outside the Boris product runtime. The product binary (`boris`) is the documentation compiler and static-site generator. This module is never compiled into that binary, never imported by any product source file, and never executed as part of normal site generation.

Within the tool family, `main.zig` is the dispatcher: it parses CLI flags, guards input/output path safety at the outermost level, and dispatches to `wordpress.run(io, gpa, opts)`. The module receives a fully constructed `RunOptions` struct—WXR path, optional media path, output directory, quiet flag—and owns everything thereafter. It does not call back into `main.zig` or any other sibling migration module.

The output tree (`content/`, `report.json`, REPORT.md, `mediamanifest.json`) is a migration artifact, not a Boris build input in the ordinary sense. A human author is expected to review the output, resolve feature codes and human-review items, and then—at their discretion—copy cleaned content into a Boris source tree for compilation. The module explicitly does not claim to produce immediately compiler-ready content for all inputs.

Relative to the source-RAG tool (`tools/source-rag/`), this module has no relationship: they are sibling tools under `tools/` that share no code and serve different workflows.

The module is exposed only via `tools/migration-lab/build.zig`'s `run` step. The root `build.zig` does not reference it, and root `zig build test` deliberately excludes it.

**Status of this file:**

- Not linked into production.
- Compiled as part of the `boris-migration-lab` executable (alongside all other migration mode modules).
- Imported by `main.zig` via `@import("wordpress.zig")`.
- Not used as a test root directly—tests are declared inline within the file.
- Not exposed through any root convenience step.

***

## Tool boundary and non-goals

**Implemented boundaries:**

- The tool opens the WXR file and optional media directory in read-only mode; it never calls any write API on those handles.
- The output directory is guarded in `main.zig` before dispatch: `--out` must differ from `--wxr` and from `--media`. This is enforced structurally before `run` is called.
- Inside `run`, a re-run wipe is scoped strictly to known sub-paths (`content/` tree, `report.json`, `REPORT.md`, `mediamanifest.json`) using explicit delete calls, not a recursive tree delete of the entire `--out` root.
- Symlinks in the media tree are detected via `isSymlink` check and rejected with `symlinkescape` reason code; the corresponding media entry is marked rejected and the page's conversion class is degraded.
- Duplicate media basenames are detected and reported as `ambiguous` rather than silently picking one.
- No network calls are present in the module or its imports (Zig standard library only).
- No subprocess invocations are present.
- PHP is never executed.
- No zip extraction.

**Documented intentions only (not mechanically enforced at module boundary):**

- Path traversal safety in media paths depends partly on `withinTreeForMedia` and `isSafeRelativePath`-style checks; whether these cover every adversarial path is not confirmed by dedicated traversal tests in available evidence.
- The `--out`-differs-from-input guard is enforced by `main.zig`, not by `run` itself; a caller constructing `RunOptions` directly could bypass it.

**Non-goals (documented and observed):**

- Does not evaluate documentation correctness.
- Does not interpret PHP template logic.
- Does not invoke an LLM.
- Does not upload data.
- Does not perform semantic link validation beyond matching against the WXR item corpus.
- Does not claim to handle all WXR variants or all WordPress plugin-emitted post types.
- Does not produce immediately publishable Boris content without human review.
- Is not part of the ordinary `boris` execution path.
- Does not change product frontmatter grammar or IR.

***

## Build and invocation model

The module has no independent build file. It is compiled as a Zig module referenced by `tools/migration-lab/build.zig`, which defines a single executable named `boris-migration-lab` with `main.zig` as the root source file. All sibling `.zig` files—including `wordpress.zig`—become reachable through imports from `main.zig`'s module graph.

The `build.zig` declares:

- `b.addExecutable(.{ .name = "boris-migration-lab", .root_module = rootmod })` — installs to `zig-out/bin/boris-migration-lab`
- `b.step("run", ...)` — runs the executable, forwarding `b.args` if provided
- `b.addTest(.{ .root_module = rootmod })` — unit tests with CWD set to the package directory (so `fixtures/` paths resolve)
- `b.step("test", ...)` — runs unit tests

There is no standalone build file for `wordpress.zig` alone. There is no separate test root for it; its inline tests run via the shared `zig build test` invocation.

The root `build.zig` does not reference `tools/migration-lab/build.zig`. Running `zig build` from the repository root does not build or test this module.

**Command table:**


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Build executable | `main.zig` + imported modules | `zig-out/bin/boris-migration-lab` | Standard target/optimize options apply |
| `zig build test` (from `tools/migration-lab/`) | Run all inline tests | Source + `fixtures/` | Pass/fail | CWD set to package dir; covers `wordpress.zig` inline tests |
| `zig build run -- --wxr <file> [--media <dir>] --out <dir>` | Run WordPress migration | WXR XML, optional media dir | `content/`, `report.json`, `REPORT.md`, `mediamanifest.json` under `--out` | `--wxr` implies `--mode wordpress` |
| `zig build --build-file tools/migration-lab/build.zig run -- --wxr <file> --out <dir>` | Same, invoked from repo root | Same | Same | Explicit build-file path required from repo root |
| `zig-out/bin/boris-migration-lab --wxr <file> --out <dir>` | Direct binary invocation | Same | Same | After `zig build install` |


***
