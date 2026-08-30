### Changed

- Removed the dead legacy `DependencyIndex.renderJson` serializer (schema
  `0.1.0` `forward`/`reverse` shape) and its test: the shipped `graph.json`
  is emitted exclusively by the IR emitter under schema `0.2.0`, so no second
  live shape for the artifact remains. Links:
  [the IR schema contract](/docs/contracts/ir-schema.md),
  [#831](https://github.com/drawmeanelephant/boris/issues/831).
