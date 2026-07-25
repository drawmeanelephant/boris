---
title: "`src/pathutil.zig` overview"
id: docs/boris/src/pathutil
status: draft
tags: [boris, zig, source-reference, pathutil]
---

# `src/pathutil.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/pathutil/surface-and-execution|Surface and execution]]
* [[docs/boris/src/pathutil/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/pathutil/review-state|Review state]]

## Executive summary

`src/pathutil.zig` is a thin compatibility re-export facade. It contains no logic of its own. Every public symbol it exposes is imported directly from `src/identity.zig` and immediately re-exported under a `pub const` alias. The file's stated purpose, written in its module-level doc comment, is to allow code that was written against a historical import path (`pathutil`) to continue to compile without modification while the canonical implementation has been centralized in `identity.zig`.

The file exists because Boris underwent a refactoring in which path and identity derivation logic was consolidated from a now-deprecated `pathutil` module into `identity.zig`. Rather than performing a bulk rename of all call sites at the time of the refactor, the author preserved `pathutil.zig` as a stable, documented shim. The module comment explicitly warns that new code **must not** use this file; it directs callers to `identity.zig` and specifically to `identity.canonicalEntityId` as the single canonical entry point.

`src/pathutil.zig` carries no executable logic, no tests of its own, and no error handling. It contributes no new declarations to the type system. Its entire contribution at compile time is a flat namespace union: every re-export resolves to the same symbol as its `identity.zig` counterpart. Any call through `pathutil.someFunction` is indistinguishable at the ABI level from a call through `identity.someFunction`.

The shim is listed in `AGENTS.md` under the "Where to edit by task" table alongside `pipeline`, `frontmatter`, `graph`, and `json_out` as part of the compiler IR / graph / diagnostics cluster, meaning it is in production linkage scope. It does not appear in any separate test-only build step; it is available to any module in the main build that imports it.

The file's coverage is entirely indirect. All tests that exercise the re-exported symbols are located in `src/identity.zig` itself, which carries a comprehensive inline test suite covering `canonicalize`, `canonicalEntityId`, `safeOutputRelativePath`, `validateEntityId`, `relativeHref`, `isPageFile`, `InputFormat`, and oversize-stem rejection. `pathutil.zig` itself is not a test root and contains no `test` blocks.

What this file does **not** provide: new behavior, additive API surface, guards, documentation of the underlying contracts, or any migration tooling. It does not enforce that callers adopt `identity.zig` directly; it merely documents that they should.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Compatibility shim / re-export facade |
| Conceptual domain | Content identity, path derivation |
| Build or test root | Neither; imported as a library module |
| Production runtime dependency | Yes — available to any production module that imports it; not isolated to tests |
| Expected execution command | `zig build` (compiled as part of main library); tests via `zig build test` exercise the underlying `identity.zig` symbols |
| Main collaborators | `src/identity.zig` (sole import and sole source of all re-exported symbols) |
| Documentation depth warranted | Low — the file is a shim with no independent logic; its canonical documentation home is `src/identity.zig` and `docs/contracts/identity-and-paths.md` |

***

## Role in the Boris architecture

`src/pathutil.zig` sits between legacy call sites and the canonical identity subsystem. It has no relationship to ApexMarkdown, the C ABI, `src/apex.zig`, or any hostile test infrastructure. It is not a test file and is not linked into any test-only build step.

**Relative to the product binary:** The file is compiled into the main build whenever any production module imports it. Because it re-exports `identity.zig` symbols verbatim, its presence in the binary is architecturally equivalent to those call sites importing `identity.zig` directly. It introduces no additional code size beyond what `identity.zig` would already contribute.

**Relative to `src/identity.zig`:** `pathutil.zig` is a strict subset view of `identity.zig`. Every symbol it exposes resolves to a symbol in `identity.zig`. It does not import any other module. The two aliases that are most notable — `isMarkdownFile` as an alias for `isPageFile`, and `entityIdFromSource` / `idFromSourcePath` as aliases for `canonicalEntityId` / `stemFromSourcePath` — suggest the historical API used different names before the terminology settled.

**Relative to the normal test suite:** The `identity.zig` inline test suite is the effective test coverage for all symbols re-exported by `pathutil.zig`. No test exercises `pathutil.zig` as an import root, so the shim itself is not directly tested; this is structurally acceptable because there is no shim logic to test.

**Relative to the overall compilation pipeline:** AGENTS.md places `pathutil` in the same task cluster as `pipeline`, `frontmatter`, `graph`, and `json_out`. This indicates it is or was a module that pipeline-stage code imports. Any such importer that has not been updated to use `identity.zig` directly continues to function correctly through this shim.

***
