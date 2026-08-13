---
title: "`src/cache.zig` overview"
id: docs/boris/src/cache
status: draft
tags: [boris, zig, source-reference, cache]
---

# `src/cache.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/cache/surface-and-execution|Surface and execution]]
* [[docs/boris/src/cache/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/cache/review-state|Review state]]

## Executive summary

`src/cache.zig` is the deterministic cache-key and incremental-rebuild module for Boris. It provides two distinct but related services: (1) a suite of pure SHA-256 fingerprinting functions that uniquely identify the build state of a rendered page from all of its contributing inputs, and (2) a reverse-dependency walk function, `getAffectedPages`, that determines which page entity IDs must be re-rendered when a source file, include, layout, or referenced page changes.

The file exists because Boris must avoid re-rendering pages whose inputs have not changed, and it must do so deterministically — identical inputs on any machine or run must produce identical fingerprints and identical affected-page sets. The fingerprint functions achieve this by hashing a carefully chosen and ordered sequence of inputs using SHA-256 via `std.crypto.hash.sha2.Sha256`, with all variable-length fields prefixed by their lengths encoded as little-endian `u64`. No timestamps, process addresses, random values, or hash-map iteration order are admitted into the digest.

The `getAffectedPages` function complements fingerprinting: when the file watcher or build driver detects that a path has changed, this function computes the minimal set of page IDs that depend — directly or transitively — on the changed path. It consults a frozen `DependencyIndex` (from `src/dependency.zig`) that records forward and reverse dependency edges keyed on paths and entity IDs. The result is sorted lexicographically and caller-owned, making it suitable for deterministic re-build scheduling.

The fingerprinting API has undergone three backward-compatible extension rounds visible in the source. `computePageFingerprint` is the original public entry point. `computePageFingerprintTheme` added optional theme material (footer and asset bytes, Feature 9.1). `computePageFingerprintThemeInput` added optional input-adapter identity (e.g. `boris-textile-adapter-v1`) to isolate Textile-mode digests from Markdown-mode digests. Each extension layer delegates to the next via a chain of calls, and each layer uses an empty-string sentinel for the new parameter to preserve all previously issued digests — callers that do not pass theme or input material continue to receive the same fingerprints they always received.

The file is compiled into the production binary (no build flag gates it), and its tests run with the normal `zig build test` harness. It has no C ABI dependencies, no allocator required for fingerprinting functions (all stack-allocated), and relies on the caller-supplied `std.mem.Allocator` only inside `getAffectedPages`.

The test suite embedded in the file directly demonstrates: determinism across two calls with identical inputs; content-sensitivity (changed bytes produce different digests); extension-layer backward compatibility (legacy call paths produce identical fingerprints to extended call paths with empty new parameters); little-endian length-prefix encoding (structural smoke only — cross-platform equivalence is asserted by construction, not by comparing against a known test vector from another platform); affected-page computation for all meaningful edge cases including page→page reference propagation and transitive include chains; and sort stability of the returned affected-pages slice.

The file does not prove: cross-architecture endianness equivalence at the byte level (no golden-vector test); correct behavior when `DependencyIndex` contains stale or dangling pointers from a non-frozen index; absence of allocation failure paths in `getAffectedPages` under adversarial allocator; or full integration with the pipeline that calls `computePageFingerprintThemeInput`.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Production module with embedded unit tests |
| Conceptual domain | Deterministic cache-key computation; incremental-rebuild dependency analysis |
| Build or test root | Compiled into the production binary; tests run via `zig build test` |
| Production runtime dependency | Yes — called by the render pipeline to determine cache freshness and rebuild scope |
| Expected execution command | `zig build test` (all tests); `zig build` (production compilation) |
| Main collaborators | `src/graph.zig` (`graph_mod.Node`), `src/dependency.zig` (`DependencyIndex`, `Dependency`, `DependencyKind`) |
| Documentation depth warranted | Medium-high — the fingerprint contract and extension-layer invariants need precise documentation to prevent future regressions |

## Role in the Boris architecture

`src/cache.zig` sits between the dependency-resolution layer and the render/emit layer in the Boris pipeline. It does not parse content, resolve graph topology, or emit HTML or JSON; those responsibilities belong to `graph.zig`, `pipeline.zig`, and similar modules. Its role is strictly to answer two questions: "Is this page's previously rendered output still valid?" and "Which pages must be re-rendered given that this path changed?"

The production binary links `cache.zig` directly. There is no build option, conditional compilation flag, or feature gate that excludes it from a release build. It does not depend on `src/render.zig` or any Markdown rendering; it is entirely self-contained aside from its two imports (`graph.zig` and `dependency.zig`) and the standard library.

`src/render.zig` and the rendering seam are orthogonal to this file. `cache.zig` has no interaction with HTML rendering.

The normal test suite for `cache.zig` runs inline — all `test` blocks are in the same file and are compiled as part of the standard `zig build test` step. There is no specialized test harness, no hostile double, and no separate test-only build target.
