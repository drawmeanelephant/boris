### Fixed

- The standalone `boris-search-index` no longer indexes Boris-owned
  `_boris/` evidence such as `_boris/proof/index.html`: recursive discovery
  prunes that subtree, explicit `--pages-file` entries under it fail closed,
  and the tool's own CLI tests now run in CI. A regenerated or `--check`
  index over a normal build output therefore matches the in-build index.
  Links: [rendered-search contract](/docs/contracts/rendered-search.md),
  [#750](https://github.com/drawmeanelephant/boris/issues/750).
