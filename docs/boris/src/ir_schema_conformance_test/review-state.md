---
title: "`src/ir_schema_conformance_test.zig` review state"
id: docs/boris/src/ir_schema_conformance_test/review-state
parent: docs/boris/src/ir_schema_conformance_test
status: draft
tags: [boris, zig, source-reference, review-state, ir_schema_conformance_test]
---

# `src/ir_schema_conformance_test.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

- The `Validator` is defined inline and is not shared with any other test module. If other tests need schema validation (e.g., `package.zig` tests validate `MACHINE-READABLE-VERSION.json`), extracting `Validator` to a shared test helper would eliminate duplication.
- The validator covers only a documented subset of JSON Schema. If the published schemas are ever extended with keywords such as `minimum`, `maxLength`, `pattern`, `if/then/else`, or `$defs` references across files, the validator will silently ignore them. A comment or assertion documenting the supported subset would reduce the risk of a false-green caused by an unsupported constraint.
- The integration test uses only `content/` as the fixture. Running the conformance check against a fixture that exercises semantic relations (IR 0.3.0) would extend coverage to the conditional schema variant. This is currently untested by this file.
- The test does not verify that the schema files themselves are well-formed JSON Schema documents beyond what `std.json.parseFromSlice` catches. A one-time check that the published schemas satisfy their own meta-schema would add confidence in schema authoring.
- The `verbose` field defaults to `true`, meaning a conformance failure prints to `stderr` during the test run. This is desirable for diagnosing failures but could be noisy if the test is run in a CI environment that expects clean stderr on success. The self-check test sets `verbose = false` explicitly to keep output clean; the integration test does not.
