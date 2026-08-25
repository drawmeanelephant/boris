# XML sitemap contract

**Status:** normative HTML projection contract for the v0.8 afterparty line.

Boris can publish one deterministic XML Sitemap Protocol file as part of a
successful HTML target transaction. A sitemap is a crawler discovery hint. Its
presence does **not** guarantee crawling, indexing, ranking, or display by any
search engine.

## CLI and configuration

```text
boris --sitemap --site-url https://docs.example/
boris --sitemap-path meta/sitemap.xml --site-url https://docs.example/
boris validate --sitemap --site-url https://docs.example/
```

- `--sitemap` enables `sitemap.xml` relative to the HTML target root.
- `--sitemap-path PATH` enables the projection and replaces that relative path.
- `--site-url URL` is the shared RSS/sitemap public deployment base.
- Sitemap selection is HTML-only and requires `--site-url`.
- RSS remains a separate projection; RSS flags and sitemap flags cannot be
  combined.
- One unqualified public base URL is ambiguous for multiple HTML targets.
  Sitemap selection therefore requires exactly one target.

For a hosted Pages publication, pass the normalized identity alongside the
sitemap URL:

```text
--pages-base-url https://owner.github.io/repository
--pages-origin https://owner.github.io
--pages-base-path /repository
```

The compiler requires `--site-url` to equal the normalized `base_url`, and
checks every emitted `<loc>` against the same origin and base path. Root sites
and custom domains pass an explicitly empty `--pages-base-path`. A mismatch is
a publication failure before target replacement, not a warning. This remains a
local artifact check; it does not verify deployment or search-engine behavior.

Configuration failures are usage errors (exit `2`). `PATH` must be non-empty,
relative, valid UTF-8, slash-separated, and contain no absolute root,
backslash, empty segment, `.` segment, `..` segment, control byte, or trailing
slash. It must not equal or nest with a page, theme/content asset, rendered
search output, `.boris-cache`, or `_boris/search` compiler-owned namespace.

The shared URL validator accepts bounded absolute `http://` or `https://`
deployment URLs only. It rejects relative and non-HTTP(S) URLs, empty or
malformed authorities, userinfo, invalid ports, query strings, fragments,
unescaped/non-ASCII authority bytes, and malformed path percent escapes.
Trailing base slashes are normalized away.

Under `boris validate`, the same configuration validator and deterministic XML
renderer receive the selected non-draft PageDb output paths. The bytes are
bounded, rendered in memory, and discarded. Validation creates no sitemap,
ownership marker, target, or stage and does not claim to test staged/live
overlay integrity; those are publication behaviors owned by `build`. See the
[validation contract](validation.md).

## XML shape

The output is UTF-8 and has exactly this structural vocabulary:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url><loc>https://docs.example/index.html</loc></url>
</urlset>
```

Only `<loc>` metadata is emitted. Boris does not emit `lastmod`, `changefreq`,
`priority`, sitemap indexes, gzip output, or `robots.txt`.

All runtime URL bytes pass through the audited structured-output XML encoder.
XML text characters are escaped. Boris URL-percent-encodes page-output path
bytes that are not RFC 3986 unreserved bytes or `/`, using uppercase hex. This
preserves Boris's actual output routes, including:

- homepage `index.md` → `index.html` → `/index.html`;
- ordinary `guide.md` → `/guide.html`;
- nested `guides/install.md` → `/guides/install.html`;
- UTF-8 path bytes, for example `café.html` → `caf%C3%A9.html`.

Boris does not rewrite `.html` routes into extensionless or trailing-slash
routes.

## Eligible URL set

The producer receives the complete current PageDb output set after rendering
and verifies each selected page exists in the staged/live overlay:

- dirty pages come from the sibling stage tree;
- unchanged incremental pages come from the live target;
- removed pages are absent from the current set.

Draft pages are excluded. Published or archived pages and pages without an
explicit status are included. Assets, rendered-search files, caches, RSS,
other projections, and stale files are never inferred by walking the output
directory and never become `<loc>` entries.

A missing selected overlay page is a build-integrity failure. A render,
validation, structured-output, link-audit, or sitemap failure publishes no
replacement sitemap and does not truncate a prior one.

## Determinism and limits

Absolute URL bytes are sorted ascending before XML emission. Duplicate absolute
URLs fail; they are not silently coalesced. For identical final eligible page
paths and `--site-url`, bytes are independent of discovery order, worker count,
incremental cache hits, locale, timezone, file mtimes, frontmatter dates, and
wall-clock time.

One sitemap is limited to:

- at most **50,000 URLs**;
- at most **50 MiB** (52,428,800 bytes) of uncompressed UTF-8 XML.

Crossing either limit is a deterministic content/build failure (exit `1`).
Boris fails without truncation and does not create an index or additional
sitemap files.

## Publication and ownership

The sitemap is created atomically inside `{target}.boris-stage` before target
commit. It is committed by the same staged publisher as HTML, assets, search,
and incremental metadata; there is no best-effort write after commit.

Boris records the current sitemap path under the target-owned
`.boris-cache/sitemap-output-path` ownership marker. When the configured path
changes or sitemap publication is disabled, the previous compiler-owned
sitemap is moved aside immediately before commit, restored if commit fails,
and removed with checked I/O after successful commit. Repeated, incremental,
parallel, watch, and failed builds therefore cannot retain an obsolete Boris
sitemap at a previously configured path.

Cross-volume whole-tree atomicity is not claimed beyond the qualified staged
publication behavior in [HTML output](html-output.md).

## Verification

Focused and aggregate gates:

```bash
zig build test-sitemap
zig build test
./scripts/release-gate.sh
```

The focused tests cover URL/path validation, XML structure and escaping,
Unicode, sorting, duplicates, both protocol limits, and forbidden metadata.
HTML integration tests cover the staged/live overlay, drafts, stale removal,
assets/search exclusion, custom paths and ownership cleanup, collisions,
failure preservation, clean/incremental/parallel byte identity, and the
single-target public URL rule.
