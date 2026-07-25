---
title: "`tools/migration-lab/wordpress_theme.zig` overview"
id: docs/tools/migration-lab/wordpress_theme
status: draft
tags: [boris, zig, tools, migration-lab, wordpress_theme]
---

# `tools/migration-lab/wordpress_theme.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/wordpress_theme/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/wordpress_theme/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/wordpress_theme/review-state|Review state]]

## Executive summary

`tools/migration-lab/theme_wordpress_theme.zig` is the implementation module for the `wordpress-theme` mode of the Boris migration laboratory. It provides a deterministic, read-only static analysis of a classic WordPress PHP theme source tree — scanning filenames, PHP source lines, and the `style.css` header for template structure, hook calls, menu and widget registrations, slot candidates, and asset provenance. It never executes PHP, loads WordPress, resolves plugin or database state, fetches remote assets, or performs any write to the source tree. Every finding is retained in structured output under the configured `--out` directory.

The file is not an entry point: it is a self-contained implementation module imported by `tools/migration-lab/main.zig` via `const wordpresstheme = @import("wordpresstheme.zig");`. The entry point for the `boris-migration-lab` executable dispatches to `wordpresstheme.run(io, gpa, opts)` for the `.wordpresstheme` mode. The file declares its own `run` function, all supporting data structures, internal scanner helpers, serialization functions, and inline tests. It is the complete implementation — not a thin wrapper — for the `wordpress-theme` analysis path.

The tool exists separately from the Boris product compiler because WordPress theme archaeology is a one-way import concern. Understanding a classic PHP theme's template hierarchy, hook calls, and slot candidates is a design problem requiring human review; it is not something the product compiler's deterministic publication pipeline can or should automate. The lab produces a bounded evidence ledger for human reviewers and a no-runtime static prototype HTML shell as a starting point, but it explicitly records evidence boundaries and never claims universal WordPress compatibility.

The executable is `zig-out/bin/boris-migration-lab`, built from `tools/migration-lab/build.zig` using `zig build` from that directory, or from the repository root with `zig build --build-file tools/migration-lab/build.zig`. The root `build.zig` does **not** include this tool; it is a fully standalone build. The tool reads a WordPress theme source directory (PHP templates, CSS, images, fonts, JS) and writes six output files — `inventory.json`, `slotmapping.json`, `manualreview.json`, `prototypemain.html`, `report.json`, and `REPORT.md` — under `--out`.

Determinism is structurally supported by lexicographic sort of file records (`fileLess`) and signal records (`signalLess`) before serialization, and by fixed field ordering in the hand-rolled JSON emitters. Two consecutive runs against the same fixture produce byte-identical output for all six artifacts; this is directly demonstrated by the `fixture mini-wordpress-kubrick deterministic inventory and review preservation` inline test. The test also verifies that specific known hook and template signals appear in the expected output files, and that the prototype HTML contains the expected slot markers.

The tool does not evaluate documentation correctness, invoke an LLM, upload data, access the network, or perform any semantic interpretation of PHP logic. PHP is never executed. Dynamic findings are always retained in `manualreview.json`; nothing is silently dropped. The fixture at `fixtures/mini-wordpress-kubrick` is synthetic (declared by both the source comment and the README) and models classic file names and behaviors without claiming to be authentic Kubrick code or to cover the full WordPress theme API surface.

Test confidence is moderate: the determinism test and the classifier unit tests are directly demonstrated. Output-directory containment (`refuseOutputInsideSource`) is unit-tested via the inline test `theme materialize refuses unsafe ledger paths` in `themematerialize.zig` (which calls the same helper from `wordpresstheme.zig`'s sibling module). The classifier `classifyTemplate` is covered by the inline `classifyTemplate classic WordPress hierarchy` test. Error paths for unreadable files, allocation failure under adversarial input, and cross-platform behavior are not directly tested.

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool implementation module |
| Conceptual domain | Migration laboratory — WordPress theme archaeology |
| Tool family | `boris-migration-lab` (standalone, `tools/migration-lab/`) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | `boris-migration-lab` (module: `wordpresstheme`) |
| Product runtime dependency | No — not linked into the `boris` product binary |
| Root build integration | Not included; standalone build only |
| Expected execution commands | `zig build run -- --mode wordpress-theme --root <theme-dir> --out <out-dir>` (from `tools/migration-lab/`) |
| Input authority | Read-only walk of `--root` theme tree; `style.css` header; PHP/CSS/asset files |
| Output ownership | All output written exclusively under `--out`; source tree never modified |
| Network or subprocess use | None — no network fetch, no PHP execution, no subprocess invocation |
| Main collaborators | `main.zig` (dispatch), `fixtures/mini-wordpress-kubrick/` (test fixture) |
| Documentation depth warranted | Medium — self-contained module; well-bounded scope |

## Role in the Boris architecture

`theme_wordpress_theme.zig` is entirely outside the Boris product runtime. The `boris` product binary does not import it, link it, or depend on it at any phase. It is compiled only as part of the `boris-migration-lab` standalone executable, via `tools/migration-lab/build.zig`. The root `build.zig` covers only the product compiler and does not include the migration laboratory; the README explicitly states that the root `zig build test` does not cover this tool.

Within the migration laboratory, the file is one of thirteen mode-implementation modules imported by `main.zig`. It is not a test root; it is a full implementation module with its own data model, scanner, serializer, and inline tests. It has no dependency on other migration-lab modules. It does not import any Boris product source files (no `src/` imports).

Relative to the Boris architecture:

- **Boris product binary**: no relationship; not linked.
- **Root `build.zig`**: no relationship; deliberately excluded.
- **`tools/migration-lab/` standalone build**: compiled as a module linked into `boris-migration-lab`.
- **Boris source files and contracts**: none imported; the module is self-contained.
- **Generated `migration-report/` output**: produces six output files under `--out`; these are generated and disposable.
- **Product content RAG**: no relationship.
- **Context Bundles**: no relationship.
- **Documentation observatory**: no relationship.
- **Other migration tools**: parallel siblings in the same binary; no shared implementation code.
- **LLM or review workflows**: the output artifacts (`inventory.json`, `manualreview.json`, `slotmapping.json`, `prototypemain.html`) are intended as human-review and design input, not as machine-authoritative records.

The file is: compiled as a separate executable (as part of `boris-migration-lab`); not linked into production; not imported by another tool; not used as a test root; not exposed through a root build convenience step.

## Tool boundary and non-goals

**What the tool is allowed to inspect:**
All files reachable by a recursive walk of `--root` that are not in a skipped directory (`.git`, `node_modules`, `dist`, `zig-out`, `.zig-cache`, `migration-report`). Text files (`.php`, `.css`, `.js`, `.mjs`, `.txt`, `.md`) are line-scanned. Binary assets are hashed and inventoried. `style.css` at the theme root is scanned for provenance metadata.

**What it is allowed to write:**
Only under `--out`. The `refuseOutputInsideSource` function enforces that `--out` must not equal or be a child of `--root`; the `run` function calls this at entry and returns `error.OutputInsideSource` on violation.

**What it does not do (implemented boundaries, not merely stated):**

- Does not modify tracked source files — structurally enforced: all source access is read-only file opens; no write path touches the source tree.
- Does not change compiler behavior — no product compiler module is imported.
- Does not change product frontmatter or IR — no Boris IR types are referenced.
- Does not perform semantic interpretation of PHP — PHP is never parsed as a grammar; only line-level substring matching against a `callrules` table is performed.
- Does not evaluate documentation correctness — output is a ledger of evidence, not a correctness judgment.
- Does not invoke an LLM — no subprocess, no HTTP.
- Does not upload data — no network calls.
- Does not access the network — structurally: no socket API is used.
- Does not act as a migration tool in the WXR sense — produces a static prototype and evidence inventory, not a Boris content tree.
- Is not part of the ordinary `boris` execution path — confirmed by build separation.

**Boundary between implemented and documented:**
The no-network and no-PHP-execution boundaries are structurally enforced (no relevant stdlib calls present). The output-containment boundary is implemented in `refuseOutputInsideSource` and called from `run`. The "never claims universal WordPress compatibility" boundary is documented; the fixture is intentionally narrow and synthetic, so the scope limitation is both stated and implicit in the fixture design.

## Build and invocation model

`theme_wordpress_theme.zig` is compiled as a Zig module linked into the `boris-migration-lab` executable. It has no standalone build file of its own. The build root is `tools/migration-lab/build.zig`.

**Module wiring:** `main.zig` declares `const wordpresstheme = @import("wordpresstheme.zig");` and calls `wordpresstheme.run(io, gpa, .{ .rootdir = opts.rootdir, .outdir = opts.outdir, .quiet = opts.quiet })` in the `.wordpresstheme` switch arm.

**Standalone build (from `tools/migration-lab/`):**

```
zig build                  # builds boris-migration-lab
zig build test             # builds and runs all inline tests
zig build run -- [flags]   # builds and runs with given flags
```

**From the repository root:**

```
zig build --build-file tools/migration-lab/build.zig
zig build --build-file tools/migration-lab/build.zig test
```

zig build --build-file tools/migration-lab/build.zig run -- --mode wordpress-theme --root <dir> --out <out>

```
```

**Direct invocation after build:**

```
./zig-out/bin/boris-migration-lab --mode wordpress-theme --root <theme-dir> --out <out-dir>
```

**Target and optimization:** Handled by `build.zig`; no mode-specific configuration is declared inside `wordpresstheme.zig` itself.

**Test artifacts:** Inline tests in `wordpresstheme.zig` are compiled into the test binary produced by `zig build test`. The determinism test writes to `fixtures/tmp-wp-theme-a` and `fixtures/tmp-wp-theme-b` and cleans up with `defer`.

**Generated artifact prerequisites:** None; the mode does not depend on any prior generated output.


| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build` (from `tools/migration-lab/`) | Build `boris-migration-lab` | `main.zig` + all mode modules | `zig-out/bin/boris-migration-lab` | Standalone only |
| `zig build test` | Run all inline tests | Source + fixtures | Test results | Covers classifier, determinism, signal preservation |
| `zig build run -- --mode wordpress-theme --root <dir> --out <out>` | Run wordpress-theme analysis | Theme source tree | 6 output files under `--out` | `--root` must differ from `--out` |
| `zig build --build-file tools/migration-lab/build.zig run -- --mode wordpress-theme ...` | Same, from repo root | Same | Same | Requires `--build-file` |
