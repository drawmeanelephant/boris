# Cooklang compatibility fixtures

Normative: [`docs/contracts/cooklang-compatibility.md`](../../cooklang-compatibility.md).

| Tree | What it proves |
|------|----------------|
| `content/` | Every accepted construct compiles: one-word and multi-word ingredients, quantities with and without units, a fraction-free and a unit-free amount, a short-hand preparation, named and anonymous timers, cookware, sections, a note, a forced line break, both comment forms, a closed `servings: 2` field, and a cross-recipe reference that must become a graph edge. It also carries a semantic relation, so the corpus exercises the IR 0.3 and 0.4 facets **together** — `relations` and `recipe` in one artifact, which is the combination that failed the published schema when `relations` reused the closed dependency-edge `kind` enum. |
| `invalid/content/` | A traversal recipe reference (`@../…`) fails the build with `ECOOKLANG`. |
| `mixed/content/` | A `.cook` page beside a `.md` page must fail closed — Boris never guesses a dialect per page. |

`content/` is also the only tree that emits the `recipe` IR facet, so
`src/ir_schema_conformance_test.zig` validates it against
[`ir-graph-0.4.0.schema.json`](../../schemas/ir-graph-0.4.0.schema.json). A
schema nobody validates is prose.
