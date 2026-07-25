---
title: "`src/json_out.zig` overview"
id: docs/boris/src/json_out
status: draft
tags: [boris, zig, source-reference, json_out]
---

# `src/json_out.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/json_out/surface-and-execution|Surface and execution]]
* [[docs/boris/src/json_out/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/json_out/review-state|Review state]]

## Executive summary

`src/json_out.zig` is a small, self-contained Zig library module that provides deterministic, pretty-printed JSON serialization primitives for the Boris compiler. Its explicit stated purpose — reflected in its module-level doc comment — is to sidestep `std.json`'s generic stringify machinery and instead write JSON keys and values in an explicitly controlled, fixed order, with 2-space indentation and LF line endings.

The file exists to give Boris a stable, reproducible output shape for its three primary artifact files — `manifest.json`, `graph.json`, and `build-report.json` — without depending on the ordering guarantees (or lack thereof) of a general-purpose serializer. Determinism in JSON output is load-bearing for Boris: downstream consumers of the IR, content-addressed cache keys, and diff-based audits all depend on the output being byte-identical across identical inputs.

The module has no production runtime dependencies beyond `std`. It is purely a collection of functions that accept a `*std.ArrayList(u8)` accumulator buffer together with an explicit `std.mem.Allocator` (the unmanaged `ArrayList` idiom used throughout the Boris codebase) and append formatted bytes. Ownership and allocation are the caller's responsibility entirely; `json_out` never allocates or frees a buffer on its own.

It is not a test file and not a hostile shim. It is a shared utility that is imported by at least two production modules — `src/ir_emit.zig` (the canonical IR artifact renderer for manifest, graph, and build-report) and `src/rag_emit.zig` (the RAG catalog JSONL renderer) — and is compiled into the main production binary through those dependencies. It contains exactly one inline test, which lives in the file itself and exercises `escapeAppend` against a trivial string containing a double-quote and a newline.

The module does not perform Unicode validation, does not handle multi-byte or surrogate-pair encoding beyond passthrough, and does not provide parsing, streaming, or schema validation. It provides no protection against caller-constructed structurally invalid JSON (e.g. missing commas, unbalanced brackets) because structural correctness is the caller's sole responsibility.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Shared utility library module |
| Conceptual domain | JSON serialization / IR output primitives |
| Build or test root | Neither — imported transitively by `ir_emit.zig` and `rag_emit.zig`; tested inline via `zig build test` |
| Production runtime dependency | Yes — linked into the main binary via `ir_emit.zig` and `rag_emit.zig` |
| Expected execution command | `zig build test` (runs the one inline test alongside all other module tests) |
| Main collaborators | `src/ir_emit.zig` (primary consumer), `src/rag_emit.zig` (secondary consumer) |
| Documentation depth warranted | Low-to-medium — the API surface is small and all functions follow a single uniform pattern; the escaping rule set and integer-width choices merit explicit documentation |

## Role in the Boris architecture

`json_out.zig` sits at the serialization leaf of the Boris pipeline. It is not involved in discovery, frontmatter parsing, graph resolution, or validation. It is reached only during the final IR emission phase, after pipeline data is frozen and ready to write.

In the normal build flow:

```text
pipeline.zig / main.zig
    → ir_emit.renderManifest / renderGraph / renderBuildReport
        → json_out.indent / writeString / writeBool / writeUsize / writeOptionalU32
    → rag_emit.renderCatalogJsonl
        → json_out.escapeAppend
```

`src/ir_emit.zig` imports `json_out` and uses the full primitive set to construct the three canonical Boris IR artifacts. `src/rag_emit.zig` imports `json_out` and uses only `escapeAppend` to produce JSONL catalog lines for the RAG export.

The module has no connection to `src/apex.zig`, the ApexMarkdown C ABI, or any hostile test infrastructure. It is unrelated to `src/apex_hostile_test.zig`, `src/hardening_test.zig`, and `src/layout_select_hostile_test.zig`.

The module is compiled into the production binary. There is no build-option or feature flag that excludes it. It carries no C dependencies, no external vendor code, and no platform-specific behavior.
