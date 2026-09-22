# Rendered-search contract fixture

This fixture freezes a small nested rendered site and the exact v1 JSON bytes
the shared producer should emit. The four pages deliberately exercise
bytewise path ordering, generated and explicit fragments, entity decoding,
separate code text, and the `data-boris-search-title` document-title override
(#881).

## Cases

| Path | Purpose | Expected handling |
|---|---|---|
| `site/` + `expected/search-index.json` | Nested-site golden | Exact byte-for-byte v1 output |
| `site/guides/title-override.html` | Marked `h2` overrides `h1` as document `title` (#881) | Golden `title` = marked heading text |
| `malformed/pages-file.txt` | `.` / `..` page-list components | Reject with `InvalidPath`; publish no replacement |
| `malformed/missing-root.html` | Required marker absent | Reject with `MissingSearchRoot` when marker mode is enabled |
| `incompatible/search-index-v2.json` | Unsupported schema version | A v1 consumer must reject it and never use it as a v1 index |

The incompatible-version case is a consumer acceptance fixture because the
browser consumer does not exist yet. It is intentionally not presented as a
passing browser test. The current standalone producer tests already cover
multiple marked roots, missing required roots, unsafe paths, and duplicates.

## Exact checks

From the repository root:

```bash
zig build --build-file tools/search-index/build.zig test
rm -rf /tmp/boris-rendered-search-contract
zig build --build-file tools/search-index/build.zig run -- \
  --root=docs/contracts/fixtures/rendered-search/site \
  --out=/tmp/boris-rendered-search-contract --quiet
cmp docs/contracts/fixtures/rendered-search/expected/search-index.json \
  /tmp/boris-rendered-search-contract/search-index.json
```

The malformed pages-file case is exercised by the CLI's existing path
validation tests; the required-marker case is exercised by the shared extractor
tests. Once a browser consumer exists, add its acceptance test for the v2 file
and wire this fixture into that consumer's focused gate.
