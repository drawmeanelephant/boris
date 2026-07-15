# Fixture skeleton: graph-native dependencies (F8.0)

**Contract target:** IR `schemaVersion` `0.2.0`
**Current status:** executable F8.2 golden

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

[`expected/edge-skeleton.json`](expected/edge-skeleton.json) remains the compact
contract pin for the complete sorted `edges` and `reverseIndex` arrays.
[`expected/graph.json`](expected/graph.json) is the executable full-artifact
golden checked by the release gate.

The edge indices used by `reverseIndex` are positions in the final sorted
`edges` array, not discovery order or hash-map order.
