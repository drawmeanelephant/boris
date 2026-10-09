### Added

- The published-output link audit shared by `boris build` and `boris validate`
  now checks the `#fragment` of every resolved local reference against the
  target page's rendered element `id` set (all elements, not only headings —
  matching `doctor`). A fragment that names no rendered anchor reports
  `EFRAGMENTMISSING` as a **warning**: it is printed and collected without
  failing the build, and the stale `href` is published verbatim rather than
  rewritten. Links:
  [diagnostics contract](/docs/contracts/diagnostics.md),
  [documentation-links contract](/docs/contracts/documentation-links.md),
  [link-fragments fixture](/docs/contracts/fixtures/link-fragments/README.md).
