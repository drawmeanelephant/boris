---
title: "`src/ir_emit.zig` evidence and cases"
id: docs/boris/src/ir_emit/evidence-and-cases
parent: docs/boris/src/ir_emit
status: draft
tags: [boris, zig, source-reference, evidence, ir_emit]
---

# `src/ir_emit.zig` evidence and cases

## Test coverage

`ir_emit.zig` contains **no inline tests**. Coverage is external:

### `src/ir_schema_conformance_test.zig`

This is the primary mechanical contract check. It runs `pipeline.run` on the `fixtures/content/valid` fixture, then validates each of the three emitted JSON files against the corresponding published JSON Schema:

- `manifest.json` → `docs/contracts/schemas/ir-manifest-0.2.0.schema.json`
- `graph.json` → `docs/contracts/schemas/ir-graph-0.2.0.schema.json`
- `build-report.json` → `docs/contracts/schemas/ir-build-report-0.2.0.schema.json`

The in-repo validator covers: `$ref` resolution against `$defs`, `type` (string, array, object, boolean, null, integer, number), `const`, `enum`, `required`, `properties`, `additionalProperties: false`, and `items`. A property emitted by the renderer but absent from the schema triggers `error.SchemaViolation`; a required property that the renderer stopped writing also triggers `error.SchemaViolation`. The test includes a self-check that the validator actually rejects drift in both directions.

**Evidence strength:** *Directly demonstrated* for the `fixtures/content/valid` fixture tree. The schemas are normative only for the base 0.2.0 IR; the conditional 0.3.0 semantic-relations output is **not** covered by a separate published schema file (uncertain whether a `ir-graph-0.3.0.schema.json` exists; not observed in the evidence).

### `src/hardening_test.zig` — "IR dual-run byte identity"

Runs `pipeline.run` twice on `fixtures/content/valid` into separate output directories, then byte-compares `manifest.json` and `graph.json`. Demonstrates that the renderers produce identical output for identical input on two separate calls. `build-report.json` is excluded because it embeds `outDir`, which differs between runs.

**Evidence strength:** *Directly demonstrated* for the specific fixture. Does not test large pages, Unicode strings with characters requiring JSON escape, or pages with semantic relations.

### `src/hardening_test.zig` — "scanner creation order cannot affect IR bytes"

Creates three pages in reverse entity-id alphabetical order, runs `pipeline.run`, then compares IR bytes against a second run on a normally ordered tree. Demonstrates that scan order does not affect `manifest.json` or `graph.json` bytes.

***

## Control flow

```text
pipeline.renderManifest(gpa, result)
    → ir_emit.renderManifest(gpa, result, VersionInfo{...})
        → artifactSchemaVersion(result, versions)
              → hasSemanticRelations(result) [scans pages]
        → buf.appendSlice("{") + jsonout.indent(1)
        → jsonout.writeString(buf, gpa, schema_version_string)
        → ... (fixed key sequence, pages loop)
        → buf.toOwnedSlice(gpa)  ← caller now owns bytes

pipeline.renderGraph(gpa, result)
    → ir_emit.renderGraph(gpa, result, VersionInfo{...})
        → graphmod.buildNav(gpa, result.pages.items)
              [allocates breadcrumb/children/siblings arrays]
        defer graphmod.freeNav(gpa, nav)
        → serialize nodes, edges, reverseIndex, nav
        → if hasSemanticRelations:
              build SemanticEdge list
              std.sort.block by (from, to, kind)
              serialize "relations" array
        → buf.toOwnedSlice(gpa)
        [defer frees nav before return]

pipeline.renderBuildReport(gpa, result)
    → ir_emit.renderBuildReport(gpa, result, VersionInfo{...})
        → serialize ok, contentRoot, outDir, pageCount, errorCount
        → if diagnostics non-empty: serialize each diagnostic object
        → buf.toOwnedSlice(gpa)
```


***
