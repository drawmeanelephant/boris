---
title: "`src/apex.zig` overview"
id: docs/boris/src/apex
status: draft
tags: [boris, zig, source-reference, apex]
---

# `src/apex.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/apex/surface-and-execution|Surface and execution]]
* [[docs/boris/src/apex/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/apex/review-state|Review state]]

## Executive summary

`src/apex.zig` is the production Zig wrapper that integrates the ApexMarkdown C engine into Boris as an in-process, synchronous function call. It owns the entire Zig/C boundary for HTML rendering: it imports `vendor/apex/apex.h` via `@cImport`, enforces the ABI contracts at the type level with comptime assertions, exposes a clean Zig-typed `render` function over the low-level C call, and contains an embedded test suite that is exercised against the real engine under `zig build test`.

The file exists at this boundary because Zig and C occupy different safety domains. Zig has no visibility into what a C implementation does with the pointers, lengths, and allocator callbacks it receives; it can only control what it sends in and how it interprets what comes back. `apex.zig` makes every commitment at the Zig side explicit and mechanical: comptime width checks, a single post-call status gate (`mapRenderResult`), a `render_mutex` to serialize the non–re-entrant C engine under `--jobs N`, a debug watermark to catch arena shrinkage, and a curated list (`remainingAbiAssumptions`) of properties the wrapper cannot prove but is correct to assume.

The module also serves as the authoritative reference for the two-sided allocator protocol. Boris passes a stack-scoped `ApexAllocator` struct whose `alloc` callback (`zigAlloc`) allocates from the caller-provided `ArenaAllocator` (the Whiteboard) and whose `free` callback (`zigFree`) is a deliberate no-op. The Whiteboard model means all C-produced HTML bytes live in the arena until `reset(.free_all)`; no `apex_free` or libc `free` is ever called on them. The `forbidApexFree` panic guard and `Html.owns_memory = false` document this invariant for future maintainers.

The module is used in production by whatever Boris pipeline phase calls `apex.render` (currently `compile.zig` and adjacent modules). It is also the root module for two distinct test binaries: `apex_tests` (linked against the real engine via `linkApex(apex_mod, b, false)`) and, indirectly, `apex_hostile_tests` (where `apex.zig` is imported as the named `"apex"` module linked against `apex_hostile.c`). The embedded U1–U18 fidelity tests and the D4 concurrency smoke (U18) are skipped in the hostile binary via `skipIfHostileEngine()`.

The file does not render HTML itself — that is the job of the linked C code. Its correctness properties are: never constructing a slice from a non-zero-status output; never passing null to C as the markdown pointer; never calling `apex_free` on arena memory; never accepting `out_html == null && out_len > 0` as a success; and serializing all C engine calls behind a mutex. What it cannot prove: that the C engine respects `md_len`, does not retain pointers after return, does not use libc `free` on custom-allocator memory, or produces `out_len` valid bytes on success. These are documented as vendor contracts.

The file's confidence is calibrated: the comptime assertions catch toolchain-level mismatches at build time; `mapRenderResult` is the sole runtime gate and is independently tested with fabricated inputs; the real-engine tests demonstrate round-trip fidelity for the pin; the hostile suite (in `apex_hostile_test.zig`) proves the gate survives adversarial C outputs. What is not proven: the C implementation's internal memory safety, the absence of race conditions inside the upstream engine under simultaneous `apex_render` calls, and the correctness of `out_ptr[0..out_len]` beyond the host's ability to ask for it.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Production Zig/C ABI wrapper + embedded real-engine test suite |
| Conceptual domain | Markdown rendering boundary; allocator lifetime; error-status safety |
| Build or test root | Root module of `apex_mod` (real engine, `zig build test`) and `apex_hostile_lib_mod` (hostile double, `zig build test-apex-hostile`) |
| Production runtime dependency | Yes — linked into the product binary; called by `compile.zig` and related HTML-producing modules |
| Expected execution command | `zig build test` (real engine tests); `zig build test-apex-hostile` (skips these tests, runs hostile suite) |
| Main collaborators | `vendor/apex/apex.h` (ABI contract), `vendor/apex/apex.c` (real C adapter), `vendor/apex/apex_hostile.c` (hostile double), `src/apex_hostile_test.zig` (hostile test root), `build.zig` (`linkApex`, `apex_mod`, `apex_hostile_lib_mod`), `docs/contracts/apex-abi.md`, `docs/contracts/parallel-rendering.md` |
| Documentation depth warranted | High — production boundary module; every exported symbol has cross-module callers and ABI implications |


***

## Role in the Boris architecture

`src/apex.zig` sits directly at the seam between Boris's Zig pipeline and the native C rendering engine. It is the only module in the codebase that calls `c.apex_render` and the only module that constructs `Html` values for consumption by downstream pipeline phases.

In the product binary, it is linked into `root_mod` (the CLI) via `linkApex(root_mod, b, false)`. The `build.zig` comment notes "default CLI does not call Apex" — the binary links the C code but `render` is only called on the HTML output path, not during IR or RAG-only runs. The Apex static libraries (`libapex.a`, `libcmark-gfm.a`, `libcmark-gfm-extensions.a`) are linked unconditionally once the product binary is built; their presence is gated on `ensure_apex.step` (the CMake bootstrap script).

In the test graph, `apex.zig` is simultaneously a *test host* (its embedded `test` blocks run against the real engine under `apex_tests`) and a *library under test* (imported as the named `"apex"` module in `apex_hostile_test.zig`, where it is linked against `apex_hostile.c`). The `build_options.hostile_apex` bool controls which tests are active in each binary.

Against the normal pipeline, `apex.zig` is a terminal rendering leaf: it accepts a `[]const u8` and an `*ArenaAllocator`, calls into C, and returns either an `Html` or an `ApexError`. It knows nothing about frontmatter, graph edges, IR schema, or output paths. Its only visible state is `render_mutex` and the file-scope `empty_md_sentinel`.

***
