---
title: "`src/layout_select_hostile_test.zig` overview"
id: docs/boris/src/layout_select_hostile_test
status: draft
tags: [boris, zig, source-reference, layout_select_hostile_test]
---

# `src/layout_select_hostile_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/layout_select_hostile_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/layout_select_hostile_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/layout_select_hostile_test/review-state|Review state]]

## Executive summary

`src/layout_select_hostile_test.zig` is an integration-level hostile test harness for Boris's page layout selection subsystem, introduced under PR #50. It does not patch or replace any production module. It exercises the `layout_select.zig` pure selector library, the `compile.zig` HTML pipeline, the `target.zig` target-spec resolution surface, and the `cli.zig` argument parser in combination, probing contract boundaries that unit tests for individual modules cannot reach. The file's module-level comment states its purpose explicitly: "Probes contract edges and records failures as test errors for the audit report."

The system boundary it protects is the interaction surface between user-supplied `--layout-rule` CLI arguments, the rule-selection algorithm in `layout_select.selectLayout`, the fallback chain resolved through `target_mod.effectiveLayout`, and the HTML output written by `compile.compileHtmlSite`. This boundary is hostile in the sense that the tests deliberately inject adversarial or edge-case rule sets — ambiguous glob combinations, path traversal strings, missing layout files, mixed theme roots, duplicate selectors, invalid selector grammars — and assert that Boris rejects them with the correct error or refuses to publish HTML output.

The file is executed both via `zig build test` (it is included in the default test step) and via the opt-in step `zig build test-layout-hostile`, as confirmed by `build.zig`. Its build module `layout_hostile_mod` links ApexMarkdown (`linkApex(..., false)`) and uses the normal `apex_opts` (not the hostile Apex double), meaning the Apex C engine it exercises is the real vendor engine. It is compiled as a standalone test binary with `src/layout_select_hostile_test.zig` as its root module; it is never linked into the production `boris` binary.

The harness provides meaningful confidence that the priority ordering (exact id > most-specific glob > role > fallback) is mechanically enforced even when rules arrive in arbitrary order; that ambiguous globs are detected and cause a build failure before any HTML is published; that path traversal attacks via `..` are rejected lexically at every CLI and library entry point; that incremental builds rewrite pages whose selected layout changed; that full and incremental builds produce byte-identical output trees; and that multi-target builds are isolated. What it does not prove: behavior under concurrent access, behavior under filesystem failure mid-build, that cycle detection in the graph is triggered by layout rule inputs, or that the real ApexMarkdown engine handles all Markdown edge cases correctly. The file's scope is deliberately confined to layout selection contracts.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Integration hostile test file |
| Conceptual domain | Layout selection, HTML compile pipeline, CLI argument parsing, incremental build correctness |
| Build or test root | Yes — root module of the `layout_hostile_mod` build module |
| Production runtime dependency | No — never linked into the `boris` executable |
| Expected execution command | `zig build test` (included) or `zig build test-layout-hostile` (opt-in alias) |
| Main collaborators | `src/layout_select.zig`, `src/compile.zig`, `src/target.zig`, `src/cli.zig`, `src/page.zig`, fixture tree at `docs/contracts/fixtures/layout-rules/hostile/` |
| Documentation depth warranted | High — exercises a multi-surface contract interaction that has no equivalent in any single unit test file |

## Role in the Boris architecture

This file sits entirely outside the production binary. The `build.zig` `layout_hostile_mod` module is created with `src/layout_select_hostile_test.zig` as its root and is added to `apex_needing` (so it depends on `ensure_apex.step`), but it is not linked into `exe` or any other installed artifact. The test binary is ephemeral, created only when `zig build test` or `zig build test-layout-hostile` is invoked.

Relative to `src/layout_select.zig`: this file imports it directly (`@import("layout_select.zig")`). `layout_select.zig` has its own embedded unit tests (reachable from `layout_select_mod` in `build.zig`) that cover the pure selector functions in isolation. `layout_select_hostile_test.zig` does not duplicate those; it instead exercises the same functions under realistic rule tables constructed from fixture paths and then confirms end-to-end HTML output through `compile.compileHtmlSite`.

Relative to `src/apex.zig` and the hostile Apex double: this file does **not** use the hostile Apex C double. It uses the real vendor engine (`hostile_apex = false` in `apex_opts`). The hostile Apex double (`apex_hostile.c`, `hostile_opts`, `apex_hostile_lib_mod`) is wired to `src/apex_hostile_test.zig` — a distinct file testing the Zig/C ABI boundary. The layout hostile test is "hostile" in a different sense: it is hostile toward the layout selection contracts, not toward the Apex ABI.

Relative to the normal test suite: `src/layout_select.zig`'s own embedded tests and the `run_layout_select_tests` build step cover pure algorithmic properties. This file covers integration properties that require a real content fixture tree, a real working directory, and real HTML compilation output.

Relative to `src/hardening_test.zig`: that file covers broader pipeline hardening concerns. This file is narrowly scoped to the layout selection surface introduced in PR #50.
