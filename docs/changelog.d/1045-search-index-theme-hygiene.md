## Fixed

- [Rendered search](/docs/contracts/rendered-search.md) now reaches the
  `<title>` fallback on doctype-led pages, and a search-excluded layout heading
  marked `data-boris-search-title` still supplies the document title without
  adding a section, so pages without an authored heading are no longer titled
  by their output path (#1045, #1047, #1048).
