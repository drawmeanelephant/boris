### Fixed

- Graph validation now detects case-only id collisions through an ASCII-fold
  key map instead of scanning all earlier ids per node, making the
  duplicate-id pass linear in graph size while keeping diagnostics
  byte-identical and first-wins ordered
  ([IR schema contract](/docs/contracts/ir-schema.md)).
