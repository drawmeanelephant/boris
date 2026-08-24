### Changed

- Dependency resolution builds its doclink source→node map once per pass via
  the shared #726 seam instead of rebuilding it for every page, removing an
  accidental O(pages × nodes) from the sequential pre-pass (~25× on a
  5,000-page corpus; output bytes identical). Documented the measured scope
  and Amdahl ceiling of `--jobs N` page-render parallelism.
  Links: [parallel-rendering contract](/docs/contracts/parallel-rendering.md),
  [#731](https://github.com/drawmeanelephant/boris/issues/731).
