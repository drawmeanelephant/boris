---
title: "`src/fuzz.zig` overview"
id: docs/boris/src/fuzz
status: draft
tags: [boris, zig, source-reference, fuzz]
---

# `src/fuzz.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/fuzz/surface-and-execution|Surface and execution]]
* [[docs/boris/src/fuzz/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/fuzz/review-state|Review state]]

## Executive summary

`src/fuzz.zig` is a bounded deterministic property-test suite that stress-tests four high-risk subsystems of the Boris compiler against random and semi-structured inputs without relying on external fuzzing toolchains. The file defines public runner functions (`runFrontmatterFuzz`, `runComponentFuzz`, `runApexFuzz`, `runGraphTopologyFuzz`) together with the top-level `test` declarations that invoke them at fixed seeds and iteration counts. A fifth test block validates the reference graph-checker against hand-constructed known cases, and a sixth asserts that the iteration constants themselves remain within documented bounds. All seeds are hard-coded so CI runs are fully reproducible.

The file exists because the four subsystems it targets — the product frontmatter parser, the `aside` component tokenizer, the `apex.zig` wrapper over the native ApexMarkdown C ABI, and the `graph.validate` function — each accept byte sequences whose structure is fundamentally adversarial at runtime. A single malformed frontmatter fence, an invalid UTF-8 byte, a null output pointer from the C engine, or a cycle in the content graph could produce a panic, a use-after-free, or silent data corruption in production. Deterministic property tests run on every `zig build test` invocation and catch regressions without requiring a separate LibFuzzer harness.

The system boundary `fuzz.zig` protects is wide but precisely scoped: it guards the parsing and validation tier (pre-IR), not the HTML assembly or file-output tier. For the Apex subsystem specifically it exercises the pointer-and-length contracts exposed by `prepareMdForC` and `mapRenderResult` — the two functions that stand between arbitrary byte payloads and the C engine — plus a no-crash property for `apex.render` itself on bounded random Markdown. It does not exercise the hostile C double (`apex_hostile.c`) or the `test-apex-hostile` build target; those are covered by `src/apex_hostile_test.zig`.

The file is compiled as a standalone Zig test root module (`root_source_file = b.path("src/fuzz.zig")`) with the real ApexMarkdown static libraries linked (`linkApex(fuzz_mod, b, false)`) and `build_options.hostile_apex = false`. It is included in the default `zig build test` step alongside all other unit-test modules. There is no separate build step — running `zig build test` is the expected invocation. The hostile Apex double is never linked when compiling `fuzz.zig`.

The confidence provided by this file is meaningful but bounded. The frontmatter fuzzer runs 256 iterations with a fixed 512-byte payload ceiling through `parser.parse`; it verifies the no-panic property and, on successful parses, the body-offset/body-slice invariant, but does not assert any particular diagnostic is emitted. The component tokenizer fuzzer verifies no-panic on valid UTF-8 and a clean `error.InvalidUtf8` on an explicit invalid sequence, but does not verify any token-level semantics. The Apex fuzzer confirms pointer-contract invariants on `prepareMdForC` and `mapRenderResult` in isolation, then verifies that `apex.render` does not crash on 128 random payloads; it does not verify HTML correctness. The graph topology fuzzer is the most structurally rigorous: it uses an independent O(n²) reference checker (`referenceCheck`) and requires the five error categories (`dup_id`, `self_parent`, `missing_parent`, `not_trunk`, `cycle`) to agree between the reference and production checkers across 200 random topologies of up to 12 nodes.

What the file does not prove: correctness of parsed output, completeness of error messages, absence of memory leaks (the arena allocator conceals leak patterns within a build), thread safety of any subsystem, behavior on inputs larger than 512 bytes, behavior of the real ApexMarkdown C implementation on adversarial inputs, or any property of the file-system scanner or IR serializer.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Bounded property/fuzz test suite |
| Conceptual domain | Parser hardening, ABI contract verification, graph validation correctness |
| Build or test root | `src/fuzz.zig` (standalone test root module in `build.zig`) |
| Production runtime dependency | None — test-only; not linked into product binary |
| Expected execution command | `zig build test` (included in default test step) |
| Main collaborators | `src/parser.zig`, `src/aside.zig`, `src/apex.zig`, `src/graph.zig`, `src/diag.zig` |
| Documentation depth warranted | Medium — file is well self-documented; threat model and cross-subsystem agreement logic warrant explicit analysis |

## Role in the Boris architecture

`fuzz.zig` sits entirely outside the product binary. The `build.zig` `fuzz_mod` is a test-only module: it is compiled into a test executable (`fuzz_tests`) that is run by `run_fuzz_tests` and depended on by the default `test` step. The product `boris` executable and the `boris-package` tool have no link-time dependency on `fuzz.zig`.

Relative to `src/apex.zig`, `fuzz.zig` is a caller, not a replacement. It imports `apex.zig` directly (`const apex = @import("apex.zig")`) and invokes `apex.prepareMdForC`, `apex.mapRenderResult`, and `apex.render` against the real ApexMarkdown static libraries. This contrasts with `src/apex_hostile_test.zig`, which is a separate root module that imports `apex` via a named build-system import and links `vendor/apex/apex_hostile.c` instead of the real engine. `fuzz.zig` never touches the hostile C double.

Relative to `src/graph.zig`, `fuzz.zig` is a parallel-path correctness verifier. It implements an independent O(n²) reference checker (`referenceCheck` / `RefProblems`) that is structurally independent of `graph.zig`'s hash-map-based DFS and then asserts category-level agreement across random topologies. This is the only location in the repository where such an independent oracle exists for graph validation.

The normal unit-test suite embedded in `graph.zig` itself tests specific named topologies at fixed inputs. `fuzz.zig` covers the combinatorial space of random topologies and catches disagreements between the production implementation and the reference checker that fixed-input tests might miss.
