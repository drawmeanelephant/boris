<!--
Filename: 881-search-title-marker.md
-->

### Fixed

- The rendered-search producer no longer honors an undocumented `data-boris-search-title` heading attribute that let any marked heading claim a document's `title`. The rule shipped with the original extractor, was never emitted by a layout and never described in the contract; title resolution is now the documented first-`h1` fallback alone, and a regression test pins the removal. Links: [the rendered-search contract](/docs/contracts/rendered-search.md), [#881](https://github.com/drawmeanelephant/boris/issues/881).
