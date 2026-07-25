---
title: "`src/hardening_test.zig` surface and execution"
id: docs/boris/src/hardening_test/surface-and-execution
parent: docs/boris/src/hardening_test
status: draft
tags: [boris, zig, source-reference, surface, testing, integration]
---

# `src/hardening_test.zig` surface and execution

## Threat model

`hardening_test.zig` does not exercise a hostile or adversarial C implementation. Its threat model is instead a set of **correctness regressions** that could arise from implementation changes to the Zig subsystems themselves:

**Non-deterministic serialization.** A pipeline or emitter that incorporates a non-deterministic ordering (e.g., hash-map iteration order, unsorted file lists, timestamp embedding) would produce different `manifest.json` or `graph.json` bytes on repeated runs. The dual-run byte-identity tests catch this category directly.

**Scanner enumeration order dependency.** If the scanner sorted pages by discovery order rather than by normalized path, inserting a file alphabetically earlier or later would change the positions of all subsequent pages in the manifest. The scanner order test writes files in reverse alphabetical order and asserts that the emitted `pages.items[0..2]` are sorted lexicographically regardless.

**Duplicate ID masking by map overwrite.** An ID-to-node map that silently overwrites a collision would produce a valid-looking manifest with one document missing and no diagnostic. The duplicate-ID test calls `graph_mod.validate` directly with two nodes sharing the same ID and asserts that (a) an `EDUPLICATEID` diagnostic is emitted, (b) the diagnostic message names at least one of the colliding paths, and (c) the `nodes` slice still has length 3 — meaning neither node was dropped before validation.

**Divergence between IR and RAG graph diagnostics.** If `pipeline.run` and `rag.run` use different graph validation paths, a structural error visible in one output might be silently absent in the other, giving downstream consumers inconsistent views of the content graph. The shared-diagnostics test drives both pipelines over six error-fixture trees and asserts that the deduplicated, sorted sets of error codes are equal.

**Output path traversal.** A page with an `id` containing `..` segments or an absolute path prefix could cause Boris to write files outside the configured output root. The path-containment test calls `identity.safeOutputRelativePath` and `identity.ragPagePath` with traversal and absolute inputs and asserts that each returns a documented error (`error.IllegalSegment`, `error.AbsolutePath`, `error.EmptyId`).

**Unregistered component propagation.** A `&lt;Figure>` or other non-registered component tag that passes through without a diagnostic could silently corrupt downstream HTML. The component tests verify that an unregistered component in source Markdown causes `pipeline.run` to return `ok = false` with an `ECOMPONENT` diagnostic.

**Raw component tag leaking into HTML or RAG output.** A registered `&lt;Aside>` or `&lt;Details>` that is not properly transformed might appear verbatim in emitted HTML or RAG Markdown. The Aside and Details tests read actual emitted files and assert that literal `&lt;Aside` and `&lt;Details` strings are absent, while the expected rendered or serialized forms are present.

**HTML rendering instability across job counts and incremental mode.** If parallel or incremental builds produce different HTML than sequential single-job builds, downstream consumers would receive non-reproducible output. The Details determinism test drives `compile.compileHtmlSite` with `jobs=1`, `jobs=2`, and `incremental=true` and byte-compares the emitted HTML files for all combinations.

**Categories not covered by this file:** ABI layout mismatch, hostile C status codes, invalid output pointer/length combinations, allocator callback misuse, reentrancy hazards, integer-width assumptions, or any behavior injectable from `apex_hostile.c`. Those are out of scope; they are exercised by `src/apex_hostile_test.zig`.

## Test harness construction

The module root is `src/hardening_test.zig`. In `build.zig` it is declared as:

```zig
const hardening_mod = b.createModule(.{
    .root_source_file = b.path("src/hardening_test.zig"),
    .target = target,
    .optimize = optimize,
});
linkApex(hardening_mod, b, false);
hardening_mod.addOptions("build_options", apex_opts);
const hardening_tests = b.addTest(.{ .root_module = hardening_mod });
const run_hardening_tests = b.addRunArtifact(hardening_tests);
run_hardening_tests.setCwd(b.path("."));
```

`linkApex(hardening_mod, b, false)` compiles `vendor/apex/apex.c` (not `apex_hostile.c`) and links the three static archives built by `scripts/build-apex-markdown.sh`. `apex_opts` sets `build_options.hostile_apex = false`. The module therefore sees the real ApexMarkdown engine throughout; there is no mechanism by which the hostile double can be substituted accidentally.

The `run_hardening_tests` step sets its working directory to the repository root (`b.path(".")`), which is required because the tests reference relative fixture paths such as `fixtures/content/valid`, `docs/contracts/fixtures/duplicate-ids/content`, and `test/fixtures/component-fail/content` that must resolve from the repository root.

`hardening_tests` depends on `ensure_apex.step` (the `build-apex` CMake script) via the `apex_needing` array in `build.zig`, so the static libraries are built before compilation begins.

No imports named `apex` are injected into `hardening_test.zig` itself; the file imports only standard Zig modules and Boris source modules (`pipeline`, `rag`, `diag`, `graph_mod`, `aside`, `compile`, `identity`, `scanner`, `page_mod`). The file has no compile-time options of its own.

The production binary (`boris`) also links the real Apex and uses `apex_opts` (hostile_apex = false). There is no build path by which the hardening test module could be accidentally included in the production binary: it is registered only as an `addTest` artifact, never as a dependency of `exe` or `source_rag_exe` or `package_exe`.

Invocation commands:

- `zig build test` — runs all suites including hardening
- `zig build test-harness` — runs only `run_hardening_tests` (alias step defined in `build.zig`)
