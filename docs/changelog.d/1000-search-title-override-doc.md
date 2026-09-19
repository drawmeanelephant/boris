## Docs

- Documented the [rendered-search](/docs/contracts/rendered-search.md)
  `data-boris-search-title` marker: a marked heading overrides the document
  title (last one wins), falling back to first `h1`, `<title>`, then the
  canonical path — previously shipped behavior known only from the source
  (#881), now pinned by a contract fixture and unit tests.
