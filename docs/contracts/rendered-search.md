# Rendered-site search artifacts

**Status:** normative v1 contract for the shared rendered-output producer,
compiler publication, standalone CLI, and browser consumer. Neither consumer
is a second producer or a reason to widen this format.

## Source and ownership

The producer consumes the exact final HTML pages under one rendered output
root. It never reads Markdown, PageDb, IR, or RAG. The shared implementation is
`src/search_index.zig`; `tools/search-index` is its standalone CLI wrapper.

The compiler passes its staged live-page overlay to that same producer; it does
not reconstruct this JSON or extract from source content. The target publisher
owns stale-file cleanup as part of the staged target commit. The producer writes
only the requested artifact and does not sweep unrelated files.

## Published files

For a rendered root `dist` and search output directory
`dist/_boris/search`, the only v1 artifact is:

```text
dist/_boris/search/search-index.json
```

The output directory is configurable by the standalone `--out` option. If it
is nested under the rendered root, recursive page discovery excludes that
directory so the index cannot index itself. Publication uses atomic replacement
for the file on the normal same-volume rename path. No manifest, shard, or
client-side database is part of v1.

## Format and schema version

The root object is JSON UTF-8 with these required fields:

| Field | Type | v1 meaning |
|---|---|---|
| `format` | string | Exactly `boris-rendered-search-index` |
| `schema_version` | integer | Exactly `1` |
| `documents` | array | Zero or more rendered-page documents |

The version is the artifact schema version, not the Boris product or IR
version. A breaking shape or semantic change increments `schema_version`.
There are no optional root fields in v1.

Each `documents` item requires:

| Field | Type | v1 meaning |
|---|---|---|
| `path` | string | Canonical output-relative HTML path |
| `title` | string | Normalized page title |
| `sections` | array | Ordered section records, possibly empty |

Each section requires all of these fields:

| Field | Type | v1 meaning |
|---|---|---|
| `level` | integer | `0` for content before the first heading, otherwise heading level `1`–`6` |
| `heading` | string | Normalized rendered heading text; empty for level zero |
| `fragment` | string | Rendered heading `id`, or the producer's generated slug |
| `text` | string | Normalized searchable prose, excluding code |
| `code` | string | Normalized searchable code text |

There are no optional document or section fields in v1. Consumers must ignore
unknown fields in otherwise valid v1 objects so additive producer metadata does
not break them. Consumers must reject the artifact (and avoid using stale or
partially parsed data) when `format` is wrong, `schema_version` is unsupported,
or a required field has the wrong type or is missing. A future incompatible
version must ship a separate contract and consumer support; it is not silently
interpreted as v1.

## Canonical paths and input selection

`path` is relative to the rendered root, uses `/` separators on every host, and
is emitted without a leading slash, `.` component, `..` component, empty path
component, or backslash. It ends in lowercase `.html`. It is a URL/path
identifier, not a filesystem absolute path and not a URL with origin, query, or
fragment. The producer does not URL-encode it; the browser consumer must safely
join it to the same-origin rendered root and must encode it when constructing a
URL if required by the host.

Because v1 stores target-relative paths rather than public URLs, a rendered
search artifact has no applicable publication origin/base-path assertion of its
own. The HTML publication gate checks the browser-facing theme/search route and
the publication checks bind search documents to the selected HTML page set;
neither result is a claim that an external deployed search request succeeded.

Without `--pages-file`, the CLI recursively discovers regular files whose path
ends in lowercase `.html`, rejects symlinks, and excludes the configured output
directory when nested below the root. With `--pages-file`, every non-empty line
is an exact output-relative `.html` path subject to the same separator,
component, regular-file, and no-symlink rules. Duplicate entries fail closed.

## Extraction and normalization

The preferred extraction root is one `<main data-boris-search-root>`. Multiple
marked roots fail. With `--require-root-marker`, a missing marker fails;
otherwise the producer falls back to the first `<main>`, then the first
`<article>` or `role="main"`, then the first `<body>`. Those marked or semantic
content roots are declared roots: `<header>` and `<aside>` descendants stay
searchable so authored asides and article headers remain indexed. When the
producer falls back to `<body>` or the whole document, `<header>` and `<aside>`
are treated as layout chrome and skipped. Navigation, footer,
executable/non-visible elements, and regions marked
`data-boris-search-exclude`, `data-boris-search-ignore`, or `data-boris-noindex`
are never indexed. Nested markup inside an excluded region does not re-enter
the index.

Rendered entities (`amp`, `lt`, `gt`, `quot`, `apos`, `nbsp`, and numeric
character references) are decoded before title, heading, fragment, text, or
code is stored. ASCII whitespace is collapsed to one U+0020 and trimmed at
both ends. Table cells (`td`/`th`) and `<br>`/`<hr>` are word separators in
`text`, so adjacent cells do not concatenate. Other UTF-8 text is preserved;
there is no case folding, stemming, punctuation removal, or language-specific
normalization. Code is kept in `code` rather than merged into `text`.

Sections retain document order. Text before the first heading is level zero;
each `h1`–`h6` begins the next section. An explicit heading `id` is copied as
`fragment` after the same entity decode, so the fragment matches the live DOM
id; absent ids use the current ASCII slug behavior (lowercase ASCII
alphanumerics separated by single dashes). Documents are sorted by canonical
`path` using bytewise ordering. The producer emits documents and sections in
that order and emits the fixed v1 keys in a stable order.

## Determinism, escaping, and trust boundary

For the same ordered set of bytes in the selected HTML pages, the same options,
and the same producer version, the JSON bytes are deterministic. Filesystem
directory enumeration order, mtime, host path separator, and worker scheduling
do not affect the result. This guarantee ends at input selection and rendered
HTML: the contract does not promise identical output when HTML, selected-page
lists, producer code, or extraction options differ.

All JSON string values are escaped by the producer. HTML is treated as rendered
input from the trusted Boris layout/content pipeline; the search extractor is
not an HTML sanitizer and does not make author text safe for insertion into
HTML. A browser UI must render fields as text, not inject them as markup, and
must treat `path`/`fragment` as data when constructing links.

## Empty sites and malformed artifacts

An empty rendered site is successful and publishes a valid artifact with
`"documents": []`. A missing required extraction marker, multiple marked roots,
unsafe/duplicate page-list entry, symlink, unreadable page, or malformed input
that prevents the selected page from being indexed fails the producer closed;
it must not publish a replacement partial index. The focused examples live in
[`fixtures/rendered-search/`](fixtures/rendered-search/): the nested-site
golden, malformed pages list, malformed extraction case, and incompatible v2
artifact.

## Consumer and cleanup rules

The browser UI consumes only the documented v1 fields: `documents[].path`,
`title`, `sections[].level`, `heading`, `fragment`, `text`, and `code`, after
checking the root `format` and `schema_version`. It must ignore unknown fields,
show no results for an empty `documents` array, and refuse incompatible or
malformed artifacts rather than falling back to an older stale file. The UI
does not own artifact generation or stale-file cleanup.

The target publisher owns cleanup of stale search artifacts as part of its
atomic target commit. Search-index generation owns only replacement of the
current `search-index.json`; it must not delete pages, layouts, or other files
under the target.

This marker is layout-only and does not change Trunk/Satellite, frontmatter,
graph, IR, or RAG contracts.

## Verification

Focused producer tests:

```bash
zig build --build-file tools/search-index/build.zig test
zig build --build-file tools/search-index/build.zig run -- \
  --root=tools/search-index/fixtures/site \
  --out=/tmp/boris-rendered-search-check
```

The contract fixture can be checked against the producer with:

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=docs/contracts/fixtures/rendered-search/site \
  --out=/tmp/boris-rendered-search-contract
cmp docs/contracts/fixtures/rendered-search/expected/search-index.json \
  /tmp/boris-rendered-search-contract/search-index.json
```

Compiler integration is covered by `src/compile.zig` tests for the staged
overlay, stale-page removal, and an empty site. The default browser UI validates
the v1 root marker and fields before rendering text-only result links; its
no-JavaScript fallback remains ordinary documentation navigation.
