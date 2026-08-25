### Fixed

- Search marker detection now matches attribute names instead of raw substrings,
  so a marker name appearing inside another attribute's value — such as a
  slugified heading id on a page documenting the markers — no longer registers a
  second search root, and `aria-hidden="false"` no longer excludes visible
  content from the index. Links:
  [the rendered-search contract](/docs/contracts/rendered-search.md).
