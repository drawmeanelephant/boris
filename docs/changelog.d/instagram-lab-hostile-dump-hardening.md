### Fixed

- Instagram migration-lab now refuses media URIs that escape the dump on read or
  the output root on write (parent traversal, absolute paths, Windows separators,
  drive prefixes). Such records are classed `human_review` with an explicit
  rejection note instead of being copied and reported as `exact`.
- Instagram captions are fenced with a backtick run longer than any run they
  contain, so an untrusted caption can no longer close the fence and inject raw
  Markdown/HTML into generated pages.
- Instagram caption provenance distinguishes `suspected-mojibake-unrepaired` from
  `utf-8`: mixed escaped/genuine Unicode and doubly-encoded captions are flagged
  for review rather than reported as clean. See
  [`tools/migration-lab/README.md`](../tools/migration-lab/README.md).
