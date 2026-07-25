---
title: "`src/ir_schema_conformance_test.zig` surface and execution"
id: docs/boris/src/ir_schema_conformance_test/surface-and-execution
parent: docs/boris/src/ir_schema_conformance_test
status: draft
tags: [boris, zig, source-reference, surface, ir_schema_conformance_test]
---

# `src/ir_schema_conformance_test.zig` surface and execution

## Threat model

This file does not protect a C ABI boundary. Its threat model is about **schema–emitter drift** rather than hostile native code. The categories of failure it is designed to detect are:

**Emitter regression — required property dropped.** The `ir_emit.zig` serializer is refactored and a required field is silently removed from the output. Consumers parsing the artifact will encounter a missing key and fail unpredictably. The validator's `required` check catches this directly.

**Emitter extension — undescribed property added.** The emitter adds a new field to an artifact without updating the published schema. Consumers who trusted the schema to be complete will not know the field exists. The `additionalProperties: false` path in the validator catches this.

**Schema drift without emitter change.** A developer edits the published `.schema.json` file (perhaps to describe a planned feature) without the emitter having been updated. The test runs `pipeline.run` against real content, so the emitted artifact is always fresh; any schema-to-artifact mismatch is caught on the next run.

**Type mismatch.** The emitter changes a field from a string to an integer or other type. The validator's `type` check catches this for scalar and compound types including `array` and `object`.

**Enum value outside allowed set.** The emitter writes a field value (e.g., a status string) that the schema constrains via `enum`. The validator's enum check catches this.

**Const constraint violation.** A field defined with `const` in the schema (a single fixed value) is changed by the emitter. The validator checks scalar equality.

**Validator is a no-op (silent pass).** The second test block directly verifies that the validator rejects missing required properties, extra properties, and wrong types. Without this self-check, a validator bug could produce a false green.

The following threat categories are **not** covered by this file:

- ABI or pointer safety (no C code is directly tested here)
- Semantic correctness of IR content (entity IDs, parent links, graph edges)
- Schema evolution or backward compatibility across schema versions
- Malformed or adversarial input to `pipeline.run` (covered by `hardening_test.zig` and `fuzz.zig`)
- Full JSON Schema draft compliance (the validator covers only the subset used by these schemas)
