# Rendered-site search index

`boris-search-index` consumes final rendered HTML and emits one deterministic
`search-index.json`. It never indexes Markdown, PageDb, IR, or RAG.

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

Long options accept either `--option value` or `--option=value`. Use
`--pages-file=live-pages.txt` for an exact output-relative live-page list;
otherwise lowercase `.html` files are discovered recursively. Use
`--require-root-marker` to require `<main data-boris-search-root>` on every
page. Without it, extraction falls back to the first `<main>`, then `<body>`.

The extractor excludes navigation/footer, executable or hidden content, and
explicit `data-boris-search-exclude` regions. Pages-file paths are normalized
and duplicate or symlinked entries fail closed. The output tree is excluded
from recursive discovery, and published indexes use atomic replacement.
Headings become ordered sections and retain their rendered `id` as the
fragment. Browser UI and staged compiler wiring are intentionally next cards;
a future compiler integration will call this same module over its staged
target rather than grow a second parser.
