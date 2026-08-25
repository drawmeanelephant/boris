### Changed

- The HTML compile path builds its wiki and documentation-link node maps once
  per render pass instead of once per rendered page, making large-site builds
  measurably faster with byte-identical output. See
  [#726](https://github.com/drawmeanelephant/boris/issues/726) and
  [#732](https://github.com/drawmeanelephant/boris/pull/732); behavior is pinned
  by the shared-map equivalence test in [wikilink](/src/wikilink.zig).
