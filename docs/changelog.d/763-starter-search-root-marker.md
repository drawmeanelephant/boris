<!--
Filename: 763-starter-search-root-marker.md
-->

### Fixed

- A fresh `boris init` site now passes `boris-search-index
  --require-root-marker` out of the box: the starter layout's content root
  carries the `<main data-boris-search-root>` marker preferred by
  [rendered search](/docs/contracts/rendered-search.md). Default indexing is
  unchanged — the same element was already the unmarked fallback root.
  Issue #763.
