---
title: "`src/ir_schema_conformance_test.zig` overview"
id: docs/boris/src/ir_schema_conformance_test
status: draft
tags: [boris, zig, source-reference, ir_schema_conformance_test]
---

# `src/ir_schema_conformance_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/ir_schema_conformance_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/ir_schema_conformance_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/ir_schema_conformance_test/review-state|Review state]]

## Executive summary

`src/ir_schema_conformance_test.zig` is a standalone test binary that mechanically validates the JSON IR artifacts emitted by Boris's production pipeline against the machine-readable JSON Schema files published under `docs/contracts/schemas/`. It exists because a published JSON Schema that has silently drifted from the emitter is, as the file's own comment states, worse than no schema at all — it misleads downstream consumers who generate parsers or validators from those published schemas rather than from prose. The test enforces bidirectional conformance: it fails if the emitter drops a property that the schema marks required, and it also fails if the emitter writes a property the schema does not describe (covered by `additionalProperties: false`).

The system boundary it protects is the published machine contract between Boris and any IR consumer. `docs/contracts/schemas/` contains versioned JSON Schema files (`ir-manifest-0.2.0.schema.json`, `ir-graph-0.2.0.schema.json`, `ir-build-report-0.2.0.schema.json`). These are normative for consumers who parse Boris IR. The prose counterpart (`docs/contracts/ir-schema.md`) remains the normative human-readable contract; the test is its mechanical twin. Without this test, either side of the contract — emitter or schema — could diverge silently between releases.

Execution follows the standard Zig test runner. The file is the root module for a dedicated test binary named `irschematests` in `build.zig`. It is included in the default `zig build test` aggregate step, and also reachable as `zig build test-ir-schema`. The test binary calls `pipeline.run` against the real `content/` fixture tree, writes the three IR artifacts to a temporary directory under `test-output/ir-schema-conformance/`, then parses and validates each artifact in memory against the corresponding published schema. The temporary output tree is cleaned up on both success and failure via a `defer` statement.

The file contains two Zig `test` blocks: `"published IR schemas match freshly emitted IR"` and `"conformance validator actually rejects drift"`. The second test is a self-check: it constructs a tight inline schema and exercises the validator against conforming and non-conforming JSON, proving the validator itself is not a no-op. This is a meaningful guard against a silent-pass bug in the validator.

The file provides high confidence that the three published IR JSON Schemas accurately describe the bytes Boris currently emits. It does not validate the content semantics of IR artifacts (e.g., that IDs are correctly assigned or that graph edges are accurate), only their structural shape relative to the schema. It also does not test schema evolution, multi-version compatibility, or consumer-side parsing.

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | Integration test with inline validator |
| Conceptual domain | IR schema contract enforcement; emitter–schema bidirectional drift detection |
| Build or test root | Root module of the `irschematests` build target (`build.zig`); included in `zig build test` aggregate and `zig build test-ir-schema` dedicated step |
| Production runtime dependency | None — compiled only for tests, never linked into the `boris` product binary |
| Expected execution command | `zig build test-ir-schema` (dedicated) or `zig build test` (aggregate) |
| Main collaborators | `src/pipeline.zig` (emitter), `src/ir_emit.zig` (artifact serialization), `docs/contracts/schemas/*.schema.json` (published contracts), `content/` (fixture input), `std.json` (parser) |
| Documentation depth warranted | Medium — the file is small and self-contained, but the contract it enforces is production-normative |

## Role in the Boris architecture

This file is not linked into the product binary under any build configuration. It is compiled exclusively as a test binary root module. The `build.zig` declaration is unambiguous:

```zig
const irschemamod = b.createModule(.{
    .root_source_file = b.path("src/ir_schema_conformance_test.zig"),
    ...
});
const irschematests = b.addTest(.{ .root_module = irschemamod });
```

The binary is separate from the main pipeline unit tests (`unittests`) and from the Apex hostile tests (`apexhostiletests`). It sits in a different layer of the test suite: not a unit test of a single module, and not a boundary-hostile ABI test, but an end-to-end integration test that exercises the full `pipeline.run` call and then validates the on-disk output against external schema files.

Relative to `src/apex.zig`, this file does not test the Apex wrapper at all. It links Apex because `pipeline.zig` depends on Apex for Markdown rendering, and `linkApex` is applied to the `irschemamod` module with `hostile = false` (the real vendor engine). The Apex integration is an implicit prerequisite for `pipeline.run` to succeed, not the subject of this test.

Relative to `src/ir_emit.zig`, this file is the external validator of everything `ir_emit.zig` serializes. The `ir_emit.zig` module writes the three IR JSON artifacts; this test reads them back and checks that their shape matches the published schemas. If `ir_emit.zig` adds or removes a field, this test will catch the drift.

The file is entirely absent from the product binary. There is no build path that could link it into the `boris` executable.
