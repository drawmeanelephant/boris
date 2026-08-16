### Fixed

- Rendered search now keeps table cells and line breaks as separate searchable
  words, and decodes HTML entities in the `<title>` fallback and heading
  `fragment` ids so result links match the live DOM. Links:
  [the rendered-search contract](/docs/contracts/rendered-search.md).
