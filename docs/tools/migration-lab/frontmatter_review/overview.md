---
title: "`tools/migration-lab/frontmatter_review.zig` overview"
id: docs/tools/migration-lab/frontmatter_review
status: draft
tags: [boris, zig, tools, migration-lab, frontmatter_review]
---

# `tools/migration-lab/frontmatter_review.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/frontmatter_review/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/frontmatter_review/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/frontmatter_review/review-state|Review state]]

## Executive summary

`tools/migration-lab/frontmatter_review.zig` is a focused read-only analysis module inside the `boris-migration-lab` standalone tool. Its single responsibility is to scan a developer-supplied content tree—Markdown and MDX files—and produce a deterministic human-and-machine report of every frontmatter key that falls outside Boris's closed author grammar (`id`, `title`, `parent`, `status`, `tags`). The tool exists so that a migration author can enumerate legacy or unsupported keys in an existing content corpus before and during a Boris migration, and decide how to handle each one: map to a supported key, move the value to the body, or drop it.

This module is not an entry point. It is imported by `tools/migration-lab/main.zig`, which dispatches to `frontmatterreview.run(io, gpa, opts)` when the CLI mode is `frontmatter-review` (aliases `fm-review`, `fmreview`). The `--content DIR` flag implies this mode. The file deliberately does not import `src/frontmatter.zig` or any other Boris product module; it mirrors only the closed key list as a local constant. This is stated explicitly in the module comment.

The file is the complete implementation of the frontmatter-review feature. No additional helper module is imported beyond `std`. It provides three public categories of declaration: data types (`KeyOccurrence`, `FileReview`, `ScanResult`), the scanning and emission logic (`scanFile`, `collectFiles`, `emitJson`, `emitMd`), and the public `run` entry point with its options struct (`RunOptions`). The implementation is straightforward enough that the full feature fits in 30 KB of Zig source.

The tool reads every `.md`/`.mdx` file under the given content root (recursively, with a well-defined skip list), parses each frontmatter fence lightly (no YAML evaluation), collects key names and line numbers for every key not in the Boris grammar, and writes two deterministic output files: `frontmatterreview.json` (machine-readable, schema version 1) and `FRONTMATTERREVIEW.md` (human-readable Markdown table). Files with no frontmatter at all, or with only Boris-grammar keys, are omitted from the output. Files with an unclosed fence receive an `incompatibleFence: true` flag and appear in the output even if no unknown keys are found.

The tool's determinism relies on: lexicographic sort of discovered file paths before scanning, preservation of source-order for key occurrences within each file, and a simple hand-rolled JSON serializer with no map iteration. The sorted ordering is directly demonstrated by inline tests. No timestamps, random identifiers, or environment-dependent values are written to outputs. The outputs are written via `Io.Dir.writeFile`; there is no staging directory and no rollback. Previous outputs in the same `--out` directory are silently overwritten; files from a previous run that no longer have unknown keys are not deleted.

The module is covered by a solid suite of inline unit tests (`test scanFile …`, `test escapeMdCell …`, `test emitJson …`, `test emitMd …`) and two fixture-based integration tests (`test fixture fm-review-no-unknown`, and at least one mixed-key fixture test referenced in the code). The unit tests demonstrate correct handling of Boris keys (not flagged), unknown keys with line numbers and values, no-frontmatter files, unclosed fences, YAML list items under `tags` (skipped), pipe escaping in Markdown table cells, and the clean-run "None" branch. The fixture tests exercise the full `run` path including file I/O.

The file does not provide: semantic interpretation of key values, suggestions for migration transforms, patch or rewrite capability, any link analysis, any product compiler behavior, any LLM interaction, or any network access. It is purely an audit report tool.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer tool module (analysis) |
| Conceptual domain | Migration laboratory — frontmatter key audit |
| Tool family | `boris-migration-lab` |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | Not a separate executable; compiled into `boris-migration-lab` |
| Product runtime dependency | None — not linked into `boris` product binary |
| Root build integration | Not directly; accessed via the `tools/migration-lab/build.zig` standalone build |
| Expected execution commands | `zig build run -- --mode frontmatter-review --content DIR --out DIR` |
| Input authority | Content tree directory supplied via `--content` flag; never modified |
| Output ownership | `--out` directory: writes `frontmatterreview.json` and `FRONTMATTERREVIEW.md` |
| Network or subprocess use | None |
| Main collaborators | `tools/migration-lab/main.zig` (importer and dispatcher) |
| Documentation depth warranted | Medium — module is self-contained and well-tested; boundary is clear |


***

## Role in the Boris architecture

`frontmatterreview.zig` is one of twelve mode modules imported by `tools/migration-lab/main.zig`. It is not part of the `boris` product binary, not linked into the root `build.zig` compilation units, and not invoked by any ordinary `boris` execution path. The module comment explicitly states: "Boris core `src/frontmatter.zig` is intentionally NOT imported here."

The tool sits outside the product runtime in the same family as `obsidian.zig`, `wordpress.zig`, `notion.zig`, and similar migration lab modules. Its relationship to the product is purely informational: it reads a content tree that could later be submitted to the Boris compiler, and tells the author which keys the compiler would reject. The author then acts on that information in their own editor; the tool itself does not modify any file.

Relative to the Boris architecture:

- **`boris` product binary**: no relationship at compile or runtime.
- **Root `build.zig`**: not referenced; only `tools/migration-lab/build.zig` produces the `boris-migration-lab` executable.
- **Standalone `tools/migration-lab/` build**: `build.zig` registers a `run` step and a `test` step; both include this module indirectly through `main.zig`.
- **Boris source files used as inputs**: the content tree passed to `--content` is developer-owned; it is typically a pre-migration corpus, not the live `content/` directory of a published Boris site.
- **Generated output**: `frontmatterreview.json` and `FRONTMATTERREVIEW.md` written under `--out`; not tracked in the Boris product content graph.
- **Product content RAG**: no relationship.
- **Context Bundles**: no relationship.
- **Migration tools**: parallel to the other migration lab modes (astro, wordpress, etc.) in the same binary.
- **LLM or review workflows**: the JSON output is designed for machine-readable consumption by review workflows or upstream chat-upload tools.

The module is compiled as part of the `boris-migration-lab` executable (not as a separate executable or a test root). It is not imported by any other tool.

***

## Tool boundary and non-goals

**Implemented boundaries (enforced by code):**

- The module contains a guard in `run` that rejects any `--out` path equal to, or prefixed by, `--content`; it returns `error.OutputInsideSource` without writing anything.
- No source file is ever opened for writing; only `openFile` (read) is used on the content tree.
- The closed-grammar key list is a local constant; no product module is imported.
- No subprocess is spawned. No network call is made.
- No frontmatter keys or values are evaluated semantically; the scanner treats all values as opaque bytes.

**Non-goals (stated in module comment or structurally absent):**

- Does not rewrite any source file.
- Does not change compiler behavior or product frontmatter rules.
- Does not evaluate documentation correctness.
- Does not assess whether a key value is valid for its intended purpose.
- Does not invoke an LLM or any external service.
- Does not upload data.
- Does not serve as a migration tool; it reports, but transforms nothing.
- Is not part of the ordinary `boris` execution path.

**Boundaries that depend on caller discipline:**

- The tool relies on the caller to supply a `--content` root that does not recursively contain `--out`; the code checks string equality and prefix, but does not resolve symlinks. If the content tree contains symlinks that resolve into the output directory, no protection is in place.
- There is no check that `--content` is below a known repository root; any readable directory is accepted.

***

## Build and invocation model

The file is compiled as part of the `boris-migration-lab` binary, whose build root is `tools/migration-lab/build.zig`. That file defines a single executable target named `boris-migration-lab` with `main.zig` as its root module. `main.zig` imports `frontmatterreview.zig` as `const frontmatterreview = @import("frontmatterreview.zig")`. There is no separate build declaration for this file.

The `build.zig` registers:

- A `run` step that passes `b.args` to the executable.
- A `test` step that compiles a test binary from the same `main.zig` root module with CWD set to the package directory (`b.path(".")`), so fixture tests can open files relative to `tools/migration-lab/`.

From the repo root, the tool can also be invoked via:

```
zig build --build-file tools/migration-lab/build.zig run -- <args>
```

The `build.zig` comment explicitly states: "Not part of the product compiler or root `zig build test` gate."

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build run -- --mode frontmatter-review --content DIR --out DIR` | Scan content tree and write reports | Content tree at `DIR` | `frontmatterreview.json`, `FRONTMATTERREVIEW.md` in `--out` | Run from `tools/migration-lab/` |
| `zig build run -- --content DIR --out DIR` | Same; `--content` implies `frontmatter-review` mode | Same | Same | Mode set by flag implication in `main.zig` |
| `zig build run -- --mode fm-review --content DIR --out DIR` | Same with alias | Same | Same | `fm-review` and `fmreview` are aliases |
| `zig build test` | Run all inline and fixture tests | Fixture directories under `tools/migration-lab/fixtures/` | Test pass/fail | CWD set to `tools/migration-lab/` |
| `zig build --build-file tools/migration-lab/build.zig run -- --content DIR --out DIR` | Same as first, from repo root | Same | Same | `--build-file` required when not in `tools/migration-lab/` |


***
