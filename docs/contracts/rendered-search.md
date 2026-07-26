# Rendered search index contract

**Status:** PR-1 standalone rendered-output capability.

The search index consumes the exact live rendered HTML pages for one output
root. It never derives content from Markdown, PageDb, IR, or RAG. The standalone
CLI accepts `--pages-file` for an explicit output-relative live-page list and
otherwise discovers lowercase `.html` recursively, excluding its own
`_boris/search/` output.

Each page is an ordered document. Text before the first `h1`–`h6` is level-zero;
each heading starts a new section. Sections contain rendered heading text,
rendered heading `id` as `fragment` when present, normalized prose, and
separately searchable code text. Documents are path-sorted bytewise for stable
JSON output.

Layouts may mark the precise extraction root with `<main
data-boris-search-root>{{content}}</main>`. Multiple marked roots fail. The
standalone extractor can require the marker; otherwise it falls back to the
first `<main>`, then `<body>`. It excludes navigation/footer, executable or
non-visible content, and explicit `data-boris-search-exclude` regions.

This marker is layout-only and does not change Trunk/Satellite, frontmatter,
graph, IR, or RAG contracts. The compiler integration seam is intentional: a
future integration will pass the staged live-page overlay to this module and
publish the index in the same target commit. Browser UI, staged compiler
wiring, and query ranking are follow-up cards.
