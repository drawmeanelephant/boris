---
title: "`src/ir_schema_conformance_test.zig` evidence and cases"
id: docs/boris/src/ir_schema_conformance_test/evidence-and-cases
parent: docs/boris/src/ir_schema_conformance_test
status: draft
tags: [boris, zig, source-reference, evidence, ir_schema_conformance_test]
---

# `src/ir_schema_conformance_test.zig` evidence and cases

## Test harness construction

The test binary is assembled as follows in `build.zig`:

```zig
const ir_schema_mod = b.createModule(.{
    .root_source_file = b.path("src/ir_schema_conformance_test.zig"),
    .target = target,
    .optimize = optimize,
});
linkOliver(ir_schema_mod, oliver_mod);          // pinned Oliver via render_mod seam
const ir_schema_tests = b.addTest(.{ .root_module = ir_schema_mod });
const run_irschematests = b.addRunArtifact(irschematests);
run_irschematests.setCwd(b.path("."));        // cwd is the repository root

const test_ir_schema_step = b.step("test-ir-schema",
    "Validate emitted IR against the published JSON Schemas");
test_ir_schema_step.dependOn(run_irschematests.step);
```

The `run_irschematests` step is also added to the default `teststep` aggregate, so `zig build test` includes it. The working directory is the repository root, which is required because the test accesses `content/` as the fixture input and `docs/contracts/schemas/` as the schema source.

The module imports only `std` and `src/pipeline.zig` (via `@import("pipeline.zig")`). It does not import `src/render.zig` directly; Oliver is present only because `pipeline.zig` needs it to render Markdown. The render seam is linked via `render_mod` before this binary links.

The `Validator` struct is defined inline in this file, not imported from a shared module. It is a self-contained, intentionally limited JSON Schema interpreter covering `$ref` (local `$defs` only), `type`, `const`, `enum`, `required`, `properties`, `additionalProperties: false`, and `items`. Full JSON Schema draft semantics are not implemented and are not claimed.

The production binary cannot accidentally use this test's validator or any code from this file; it is not exported and is never linked into `boris` or any other product artifact.

Temporary output is written to `test-output/ir-schema-conformance/` relative to the working directory. The directory is deleted before the test run (to prevent stale artifact reuse) and deleted again after via `defer` on both success and failure. The path is listed in `.gitignore` (the file comment describes it as "disposable artifacts under test-output (gitignored)").

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `Validator` struct | Internal type | Self-contained JSON Schema subset validator; resolves `$ref` against `$defs`, checks `type`, `const`, `enum`, `required`, `properties`, `additionalProperties: false`, `items` | `root: std.json.Value` (schema root), `arena: std.mem.Allocator` (arena for path strings), `verbose: bool` | `validate()` returns `void` or `error.SchemaViolation` | Bidirectional emitter–schema drift |
| `Validator.resolve` | Private method | Dereferences a `$ref` pointer of the form `#/$defs/Name` against the schema root's `$defs` object | A `std.json.Value` that may or may not contain `"$ref"` | Returns the referenced schema value or `error.UnsupportedRef` / `error.MissingDefs` / `error.MissingDef` | `$ref` local-only constraint |
| `typeMatches` | Private function | Maps a JSON Schema type name string to a `std.json.Value` tag match | `name: []const u8`, `v: std.json.Value` | `bool` — true if value's tag matches the named JSON type | Type constraint checking |
| `scalarEql` | Private function | Structural equality for scalar `std.json.Value` pairs (null, bool, integer, string) | Two `std.json.Value` values | `bool` | `const` and `enum` checking |
| `Validator.fail` | Private method | Emits a diagnostic (when `verbose`) and returns `error.SchemaViolation` | Path string, comptime label, detail string | Always returns `error.SchemaViolation`; prints when `verbose = true` | Violation reporting |
| `Validator.child` | Private method | Arena-allocates a dotted child path string | Parent path and suffix | `"parent.suffix"` or error | Path tracking for diagnostics |
| `Validator.validate` | Private method | Recursive schema validation entry point; dispatches to `const`, `enum`, `type`, `properties`, `required`, `additionalProperties`, `items` checks | Schema value, document value, path string | `void` or `error.SchemaViolation` with a path-qualified message | Complete structural validation |
| `readAlloc` | Private function | Reads an entire file into a GPA-owned slice | `Io`, `Io.Dir`, relative path, `std.mem.Allocator` | Owned `[]u8` slice of file bytes | Filesystem I/O contract |
| `checkArtifact` | Private function | Orchestrates one artifact check: reads schema and artifact files, parses both as JSON, runs `Validator.validate` | `Io`, `gpa`, artifact path, schema path | `void` or error | Full per-artifact conformance check |
| `test "published IR schemas match freshly emitted IR"` | Integration test | Calls `pipeline.run` against `content/`, then calls `checkArtifact` for all three IR artifacts against their published schemas | Real content fixture, `std.testing.io`, `std.testing.allocator`, `test-output/ir-schema-conformance/` as outdir | All three `checkArtifact` calls succeed; `result.ok` is `true` | `ir-manifest-0.2.0.schema.json`, `ir-graph-0.2.0.schema.json`, `ir-build-report-0.2.0.schema.json` all describe current emitter output exactly |
| `test "conformance validator actually rejects drift"` | Validator self-check | Constructs an inline schema `{type:object, required:[a], additionalProperties:false, properties:{a:{type:string&#125;&#125;}` and runs four sub-checks: valid input, missing required, extra property, wrong type | Inline JSON literals; `verbose = false` to suppress noise | Valid document passes; missing-required, extra-property, and wrong-type each return `error.SchemaViolation` | Validator is not a silent-pass no-op |

## Hostile-case walkthrough

This file does not inject hostile C behavior. Its "cases" are schema drift scenarios. The following subsections document each meaningful validation case individually.

***

### Missing required property

**Injected behavior:**
The test constructs a document `{}` (empty object) against a schema that declares `required: ["a"]`. This simulates a regressed emitter that has stopped writing a previously-required field.

**Wrapper boundary exercised:**
`Validator.validate` → `required` branch. For each element in the schema's `required` array, the validator calls `doc.object.get(r.string)` and fails if the result is `null`.

**Expected response:**
`error.SchemaViolation` with the detail being the missing property name (`"a"`).

**Forbidden unsafe response:**
Returning `void` (treating a missing required property as acceptable), which would allow downstream consumers to encounter missing keys silently.

**Evidence strength:**
Directly demonstrated — `std.testing.expectError(error.SchemaViolation, v.validate(...))` asserts the error in the self-check test.

**Residual gap:**
The inline schema used for the self-check has exactly one required property. The test does not cover schemas with multiple required properties where a subset are missing. The production schemas have many required properties; the integration test covers those transitively but only for the happy path (all properties present). No test directly verifies partial missing-required behavior at scale.

***

### Extra property (undescribed field added by emitter)

**Injected behavior:**
The test constructs a document `{"a":"x","b":1}` against a schema with `additionalProperties: false` and `properties` containing only `"a"`. This simulates an emitter that has added a new output field without updating the published schema.

**Wrapper boundary exercised:**
`Validator.validate` → `additionalProperties` branch. When `additionalProperties` is a `bool` with value `false`, the validator iterates the document's object keys and checks each against `props.object.get(kv.key_ptr.*)`. A key absent from `properties` triggers `fail`.

**Expected response:**
`error.SchemaViolation` with the detail being the key name of the undescribed property (`"b"`).

**Forbidden unsafe response:**
Silently ignoring the extra key, which would allow a schema to become stale without detection as the emitter grows.

**Evidence strength:**
Directly demonstrated — `std.testing.expectError(error.SchemaViolation, v.validate(...))` in the self-check.

**Residual gap:**
The validator only enforces `additionalProperties: false` when the schema explicitly sets the keyword to the boolean `false`. Schemas that omit `additionalProperties` (which by JSON Schema default allows additional properties) are not covered by this check. The production schemas use `additionalProperties: false`, so coverage is complete for them, but the validator does not enforce a general "schemas must use additionalProperties:false" constraint.

***

### Wrong type

**Injected behavior:**
The test constructs a document `{"a":1}` (integer) against a schema property `a` with `type: "string"`. This simulates an emitter changing the type of a field.

**Wrapper boundary exercised:**
`Validator.validate` → `type` branch. `typeMatches(t.string, doc)` returns `false` for an integer value, causing `fail` to be called with `"type mismatch"`.

**Expected response:**
`error.SchemaViolation` with detail `"integer"` (the actual type tag name of the document value).

**Forbidden unsafe response:**
Silently accepting a type mismatch, which would allow broken output to pass the schema gate.

**Evidence strength:**
Directly demonstrated — `std.testing.expectError(error.SchemaViolation, v.validate(...))` in the self-check.

**Residual gap:**
`typeMatches` maps `"number"` to `v == .integer or v == .float`. The validator does not distinguish `integer` from `number` in the strict JSON Schema sense (where `integer` requires no fractional part). `std.json.parseFromSlice` parses JSON integers as `.integer` and JSON floats as `.float`, so the distinction is preserved at the representation level. Whether any production schema uses `type: "integer"` vs `type: "number"` with a semantic distinction is not verified here.

***

### Valid document passes

**Injected behavior:**
The test constructs a document `{"a":"x"}` conforming exactly to the inline schema (correct type, required property present, no extra properties).

**Wrapper boundary exercised:**
All branches of `Validator.validate` for a minimal schema — `type`, `required`, `additionalProperties`, `properties`.

**Expected response:**
`void` — no error.

**Forbidden unsafe response:**
Returning `error.SchemaViolation` for a valid document, which would produce false negatives on the integration test.

**Evidence strength:**
Directly demonstrated — `v.validate(schema.value, good.value, "probe")` is called without `expectError`, so the test fails if it errors.

**Residual gap:**
This is a minimal inline schema. Whether `Validator.validate` correctly handles all schema constructs used in the production schemas (nested objects, arrays, `$ref` chains, union `type` arrays) is only covered transitively by the integration test, not by an independent happy-path battery at each feature.

***

### Integration: all three IR artifacts conform to their published schemas

**Injected behavior:**
`pipeline.run` is called with the real `content/` fixture tree and the real Oliver-backed rendering seam. The three IR artifacts (`manifest.json`, `graph.json`, `build-report.json`) are written to disk and then read back.

**Wrapper boundary exercised:**
`checkArtifact` is called for each artifact/schema pair. The validator is run on each parsed document against the parsed schema.

**Expected response:**
All three calls return `void`. `result.ok` is `true` (the pipeline succeeded on the fixture).

**Forbidden unsafe response:**
A schema-conformant check passing on stale or empty artifacts. The test defends against this by deleting the output directory before the run and failing if `result.ok` is false.

**Evidence strength:**
Directly demonstrated for the current emitter output and current published schemas. If either changes without the other, this test fails.

**Residual gap:**
The fixture is `content/` (the Boris dogfood documentation content). If the fixture is small enough that certain schema branches (e.g., a page with semantic relations) are not exercised, those branches of the IR serializer are not covered by this test. Large or adversarial content fixtures are exercised in other test targets (`hardening_test.zig`, `fuzz.zig`). The test also does not verify that the schemas are themselves valid JSON Schema documents (e.g., that they could be consumed by a standard JSON Schema implementation); it only validates that the emitter output matches the subset the inline validator understands.

***

## Control flow

```text
zig build test-ir-schema
    → Zig test runner: test "published IR schemas match freshly emitted IR"
        → Io.Dir.cwd.deleteTree(workdir)        // clear stale artifacts
        → defer Io.Dir.cwd.deleteTree(workdir)  // cleanup on exit
        → pipeline.run(io, gpa, {content_root, out_dir, quiet: true})
            → full Boris compile: scan → frontmatter → graph → validate → ir_emit
            → writes manifest.json, graph.json, build-report.json to workdir
        → std.testing.expect(result.ok)
        → checkArtifact(io, gpa, workdir/manifest.json,     docs/.../ir-manifest-0.2.0.schema.json)
        → checkArtifact(io, gpa, workdir/graph.json,        docs/.../ir-graph-0.2.0.schema.json)
        → checkArtifact(io, gpa, workdir/build-report.json, docs/.../ir-build-report-0.2.0.schema.json)
            → readAlloc(schema file) → std.json.parseFromSlice → schema_parsed
            → readAlloc(artifact file) → std.json.parseFromSlice → doc_parsed
            → Validator.init(schema_parsed.value, arena)
            → Validator.validate(schema_parsed.value, doc_parsed.value, basename)
                → resolve $ref if present
                → check const / enum / type / required / additionalProperties / properties / items
                → recurse for nested objects and array items
                → error.SchemaViolation (with printed path) on any mismatch
                → void on full conformance

    → Zig test runner: test "conformance validator actually rejects drift"
        → parse inline schema
        → Validator{verbose: false}
        → validate(good)     → void           (assert passes)
        → validate(missing)  → SchemaViolation (assert error)
        → validate(extra)    → SchemaViolation (assert error)
        → validate(wrongtype)→ SchemaViolation (assert error)
```
