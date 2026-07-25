---
title: "`src/fixtures_test.zig` overview"
id: docs/boris/src/fixtures_test
status: draft
tags: [boris, zig, source-reference, fixtures_test]
---

# `src/fixtures_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/fixtures_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/fixtures_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/fixtures_test/review-state|Review state]]

## Executive summary

`src/fixtures_test.zig` is a small, self-contained test module from milestone 2 that checks the on-disk fixture corpus under the repository-root `fixtures/` directory. It verifies that the fixture tree, `manifest.json`, and category documentation stay present and internally consistent. It does **not** run the content compiler, graph validator, IR emitter, RAG export, or HTML path against those root fixtures. Compiler goldens and validation live under `docs/contracts/fixtures` and modules such as `src/hardening_test.zig` / the release gate.[^3_1]

The module hard-codes eight content-error category codes that must appear in the fixture inventory (`EDUPLICATEID`, `EPARENTMISSING`, `EPARENTSELF`, `EPARENTNOTTRUNK`, `EPARENTCYCLE`, `EFRONTMATTER`, `EINVALIDUTF8`, `EINVALIDPATH`), matching the content subset of `docs/contracts/diagnostics.md`. Five inline tests open `fixtures/` relative to the process cwd (package root), read `manifest.json` and companion files, and assert path existence, array lengths, category coverage, UTF-8 invalidity of one byte fixture, and emptiness of the empty-no-frontmatter valid page.[^3_1]

The file exists so the fixture corpus cannot silently drift: missing files, undocumentated invalid categories, or a rewritten “invalid UTF-8” file that becomes valid UTF-8 fail `zig build test` before later milestones depend on the inventory. It is inventory hygiene, not behavioral proof of the pipeline.

What this file does not prove: it does not prove that invalid fixtures actually produce the claimed diagnostic codes under `pipeline.compile`; it does not prove IR/RAG/HTML goldens; it does not scan the full tree beyond paths listed in the manifest; and it assumes tests run with cwd at the package root.[^3_1]

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Dedicated test module (fixture inventory) |
| Conceptual domain | Contract fixtures; diagnostic category documentation; corpus presence |
| Build or test root | Test-only module; no production `main`; participates in `zig build test` |
| Production runtime dependency | No — not imported by the product binary path |
| Expected execution command | `zig build test` (cwd must be package root so `fixtures/` opens) |
| Main collaborators | On-disk `fixtures/` (`manifest.json`, `README.md`, `expected/invalid-categories.txt`, `content/valid/*`, `content/invalid/*`); normative alignment with `docs/contracts/diagnostics.md` |
| Documentation depth warranted | Medium — small file (~5.7 KB), clear scope, important non-goals |


***

## Role in the Boris architecture

`src/fixtures_test.zig` is not linked into the `boris` product binary. It is a test unit that the main test step compiles and runs.[^3_1]

In relation to the overall pipeline:

- **Product binary**: No import path from `src/main.zig` or export/RAG/HTML modules into this file.
- **`src/pipeline.zig` / `src/graph.zig` / `src/parser.zig`**: Not called. The module file header states compiler goldens and validation live under `docs/contracts/fixtures` and `src/hardening_test.zig`.[^3_1]
- **Root `fixtures/` vs `docs/contracts/fixtures`**: This module only inventories the milestone-2 root `fixtures/` tree. Contract-driven pipeline tests use a different fixture root under `docs/contracts/fixtures`. Confusing the two is a common source of false “missing fixture” reports.[^3_1]
- **Normal test suite** (`zig build test`): Inline `test` blocks run as part of the default test step when the package is built with cwd at the repo root.
- **Specialized ABI / hostile / sanitizer steps**: None for this file.

Removing or skipping this module would not break shipping HTML/IR/RAG, but it would allow the root fixture inventory and category checklist to drift without a gate.

***
