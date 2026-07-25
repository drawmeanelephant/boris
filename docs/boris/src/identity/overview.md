---
title: "`src/identity.zig` overview"
id: docs/boris/src/identity
status: draft
tags: [boris, zig, source-reference, identity]
---

# `src/identity.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/identity/surface-and-execution|Surface and execution]]
* [[docs/boris/src/identity/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/identity/review-state|Review state]]

## Executive summary

`src/identity.zig` is the **single, authoritative module for canonical entity-identity and path derivation** in the Boris compiler. Its stated and enforced mandate is that every conversion of a content-root-relative source path into a graph key or an output-relative path must flow through this module—never through ad-hoc string slicing elsewhere in the codebase. The module is deliberately I/O-free: it operates on in-memory byte slices and delegates all allocation to caller-supplied allocators, making it straightforwardly testable and composable with any upstream scanner or pipeline stage.

The module exists to enforce three security- and correctness-critical invariants simultaneously: (1) path-traversal cannot escape an output root, because entity ids produced here are structurally forbidden from containing `..`, leading `/`, backslash, empty segments, or whitespace; (2) the extension policy is case-sensitive and explicit, preventing Windows-style case-folded files (`.MD`, `.MDX`) from silently entering the build graph; and (3) letter case in filenames is preserved exactly, meaning `Guides/Intro.md` produces id `Guides/Intro`—not `guides/intro`—ensuring cross-platform builds remain reproducible and case-preserving on filesystems that distinguish case.

The module is linked into the production binary (`src/main.zig` → `scanner.zig` → `identity.zig`) and into every test suite that exercises path logic. It has no conditional-compilation guards, no `hostile_apex`-style build options, and no dependency on external C libraries. Its correctness properties are protected by a rich suite of embedded `test` blocks that run as part of the `scanner_mod` test target in `build.zig` (scanner imports identity; scanner's module root is used as the test root). The tests cover both the happy path—multi-level nesting, backslash normalization, `.mdx` and `.textile`, dots inside stems—and explicit rejection of every pathological input category: absolute paths, traversal segments, empty extensions, oversize ids, wrong-case extensions, and whitespace in segments.

The module does **not** test: concurrent access (the module is fully single-threaded by design; no shared mutable state exists); behavior when an upstream caller skips `canonicalEntityId` and passes a pre-cooked string directly to `safeOutputRelativePath` (the latter re-validates but the chain is not enforced at compile time); behavior on non-UTF-8 byte strings (the module operates on `[]const u8` without Unicode normalization, treating bytes as opaque except for the ASCII characters it explicitly inspects); or behavior when the content root is not a POSIX filesystem (separator detection is limited to `/` and `\\`).

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production library module with embedded unit tests |
| Conceptual domain | Identity derivation, path canonicalization, output-path safety |
| Build or test root | Compiled as part of `scanner_mod` (root: `src/scanner.zig`) for tests; also imported transitively by `pipeline_mod`, `rag_mod`, and the product `root_mod` |
| Production runtime dependency | Yes — linked into the `boris` CLI binary via `scanner.zig` |
| Expected execution command | `zig build test` (scanner tests include this module); `zig build test-harness` does not specifically isolate it |
| Main collaborators | `src/scanner.zig` (primary consumer), `src/pipeline.zig`, `src/rag.zig`, `docs/contracts/identity-and-paths.md` (normative contract), `docs/contracts/scanner.md` |
| Documentation depth warranted | High — this is the single authoritative identity-derivation module; every path-related correctness claim in the system depends on it |

## Role in the Boris architecture

`src/identity.zig` sits at the **foundation of the content graph**. The scanner (`src/scanner.zig`) discovers files and calls `canonicalEntityId` to derive the graph key for each page. No other module is permitted to produce entity ids from raw paths. The pipeline (`src/pipeline.zig`) and RAG exporter (`src/rag.zig`) call `safeOutputRelativePath` and `ragPagePath` respectively to derive output-relative paths from already-validated entity ids. `relativeHref` is called when constructing inter-page HTML `href` attributes.

The module is **not** linked against the Apex C ABI and carries no `build_options` flag. It is equally present in the hostile-Apex test binary and the real-engine binary because it has no C dependency and no conditional compilation. The product CLI binary (`boris`) includes this module transitively through `scanner.zig`.

There is no separate "identity test" build target. The identity module's embedded tests execute when `zig build test` runs the scanner test artifact, because `src/scanner.zig` imports `src/identity.zig` and Zig's test runner discovers `test` blocks transitively within a module tree. The module's tests may also execute as part of the unit-test root (`src/main.zig`) depending on import depth. The hostile-Apex test module (`src/apex_hostile_test.zig`) imports `apex` but not `identity`; identity tests are not executed under that build target.
