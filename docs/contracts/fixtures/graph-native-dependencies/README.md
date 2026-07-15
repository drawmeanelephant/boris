# Fixture skeleton: graph-native dependencies (F8.0)

**Contract target:** IR `schemaVersion` `0.2.0`
**Current status:** shape-only; not an executable golden until F8.2

## Input topology

- `guides/child` has parent `index`.
- `index` directly includes `includes/shared.md` and directly references
  `guides/target` twice (the edge is deduplicated).
- `includes/shared.md` directly includes `includes/nested.md` and references
  `guides/target`.
- Include/wiki-looking text inside the fenced sample remains literal and does
  not produce edges.
- `includes/**` files are source endpoints, not discovered page nodes.

## Expected dependency projection

[`expected/edge-skeleton.json`](expected/edge-skeleton.json) pins the complete
sorted `edges` and `reverseIndex` arrays for these inputs. It is intentionally
not named `graph.json`: F8.0 must not claim that the v0.2.1 compiler already
emits IR 0.2. F8.2 will add the full artifact golden after implementation.

The edge indices used by `reverseIndex` are positions in the final sorted
`edges` array, not discovery order or hash-map order.
