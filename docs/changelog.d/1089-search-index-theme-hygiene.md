## Fixed

- [Rendered search](/docs/contracts/rendered-search.md) no longer fabricates a
  slug `fragment` for a heading without an `id` (the empty fragment links the
  page), so layout `<h1>{{title}}</h1>` headings stop failing the
  `rendered-search` publication check with `SEARCH_CONTENT_MISMATCH`. It also
  reaches the `<title>` fallback on doctype-led pages, lets a search-excluded
  layout heading marked `data-boris-search-title` supply the document title,
  and keeps compiler-emitted `{{relations}}`/`{{backlinks}}` and the HTML 4.01
  Strict nav, breadcrumb, TOC, and children wrappers out of the index
  (#1045, #1047, #1048).
