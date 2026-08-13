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

`src/fuzz.zig` is a bounded deterministic property-test suite that stress-tests four high-risk subsystems of the Boris compiler against random and semi-structured inputs without relying on external fuzzing toolchains. The file defines public runner functions (`runFrontmatterFuzz`, `runComponentFuzz`, `runRenderFuzz`, `runGraphTopologyFuzz`) together with the top-level `test` declarations that invoke them at fixed seeds and iteration counts. A fifth test block validates the reference graph-checker against hand-constructed known cases, and a sixth asserts that the iteration constants themselves remain within documented bounds. All seeds are hard-coded so CI runs are fully reproducible.

The file exists because the four subsystems it targets — the product frontmatter parser, the `aside` component tokenizer, the `render.zig` seam over the Oliver rendering library, and the `graph.validate` function — each accept byte sequences whose structure is fundamentally adversarial at runtime. A single malformed frontmatter fence, an invalid UTF-8 byte, a renderer failure on adversarial bytes, or a cycle in the content graph could produce a panic, a use-after-free, or silent data corruption in production. Deterministic property tests run on every `zig build test` invocation and catch regressions without requiring a separate LibFuzzer harness.

The system boundary `fuzz.zig` protects is wide but precisely scoped: it guards the parsing and validation tier (pre-IR), not the HTML assembly or file-output tier. For the rendering seam specifically it exercises a no-crash property over `render.render` on bounded random Markdown — including arbitrary bytes, since the renderer is byte-oriented — accepting `OutOfMemory`, `InputTooLarge`, `WriteFailed`, and `NoSpaceLeft` as valid outcomes alongside success. Oliver is a pure Zig library with no C ABI, so there is no pointer/length surface to probe and no hostile double; those concerns were removed with the previous C renderer.

The file is compiled as a standalone Zig test root module (`root_source_file = b.path("src/fuzz.zig")`); `linkOliver(fuzz_mod, oliver_mod)` wires the pinned Oliver module through the `render_mod` seam. It is included in the default `zig build test` step alongside all other unit-test modules. There is no separate build step — running `zig build test` is the expected invocation.

The confidence provided by this file is meaningful but bounded. The frontmatter fuzzer runs 256 iterations with a fixed 512-byte payload ceiling through `parser.parse`; it verifies the no-panic property and, on successful parses, the body-offset/body-slice invariant, but does not assert any particular diagnostic is emitted. The component tokenizer fuzzer verifies no-panic on valid UTF-8 and a clean `error.InvalidUtf8` on an explicit invalid sequence, but does not verify any token-level semantics. The renderer fuzzer verifies that `render.render` does not crash on 128 random payloads (with occasional structured Markdown); it does not verify HTML correctness. The graph topology fuzzer is the most structurally rigorous: it uses an independent O(n²) reference checker (`referenceCheck`) and requires the five error categories (`dup_id`, `self_parent`, `missing_parent`, `not_trunk`, `cycle`) to agree between the reference and production checkers across 200 random topologies of up to 12 nodes.

What the file does not prove: correctness of parsed output, completeness of error messages, absence of memory leaks (the arena allocator conceals leak patterns within a build), thread safety of any subsystem, behavior on inputs larger than 512 bytes, behavior of Oliver on adversarial inputs beyond the no-crash property (HTML correctness on complex constructs is covered by the structured fixtures in `src/render.zig` and `docs/contracts/oliver-renderer.md`), or any property of the file-system scanner or IR serializer.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Bounded property/fuzz test suite |
| Conceptual domain | Parser hardening, renderer no-crash verification, graph validation correctness |
| Build or test root | `src/fuzz.zig` (standalone test root module in `build.zig`) |
| Production runtime dependency | None — test-only; not linked into product binary |
| Expected execution command | `zig build test` (included in default test step) |
| Main collaborators | `src/parser.zig`, `src/aside.zig`, `src/render.zig`, `src/graph.zig`, `src/diag.zig` |
| Documentation depth warranted | Medium — file is well self-documented; threat model and cross-subsystem agreement logic warrant explicit analysis |

## Role in the Boris architecture

`fuzz.zig` sits entirely outside the product binary. The `build.zig` `fuzz_mod` is a test-only module: it is compiled into a test executable (`fuzz_tests`) that is run by `run_fuzz_tests` and depended on by the default `test` step. The product `boris` executable and the `boris-package` tool have no link-time dependency on `fuzz.zig`.

Relative to `src/render.zig`, `fuzz.zig` is a caller, not a replacement. It imports `render.zig` directly (`const render = @import("render.zig")`) and invokes `render.render` against the Oliver-backed seam. The renderer fuzz is a no-crash property over bounded random bytes; it never probes a C ABI because Oliver is a pure Zig library — there is no pointer/length surface and no hostile double.

Relative to `src/graph.zig`, `fuzz.zig` is a parallel-path correctness verifier. It implements an independent O(n²) reference checker (`referenceCheck` / `RefProblems`) that is structurally independent of `graph.zig`'s hash-map-based DFS and then asserts category-level agreement across random topologies. This is the only location in the repository where such an independent oracle exists for graph validation.

The normal unit-test suite embedded in `graph.zig` itself tests specific named topologies at fixed inputs. `fuzz.zig` covers the combinatorial space of random topologies and catches disagreements between the production implementation and the reference checker that fixed-input tests might miss.
