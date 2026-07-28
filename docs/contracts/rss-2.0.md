# RSS 2.0 export

**Status:** normative RSS projection contract for the v0.8 afterparty line.

`boris --rss` publishes a deterministic RSS 2.0 document from the validated
content graph. It reuses the scanner, frontmatter parser, identity rules, and
graph validation; it does not render HTML or consult filesystem timestamps.

## CLI and exits

```text
boris --rss --site-url URL --rss-title TITLE --rss-description TEXT [options]
```

`--rss-path PATH` implies `--rss`; its default is `rss.xml`. `--site-url`,
`--rss-title`, and `--rss-description` are required. `--rss-limit N` defaults
to 20 and accepts only 1 through 500. RSS is mutually exclusive with HTML, IR,
RAG, Context Bundle, `llms.txt`, `check`, and `impact` modes. Invalid flags,
missing required settings, invalid limits, and invalid site URLs exit 2;
content or feed-projection validation exits 1; I/O and publication failures
exit 3.

## Metadata and eligibility

The closed [frontmatter grammar](frontmatter.md) adds `published_at` and
`summary`. `published_at` is exactly `YYYY-MM-DDTHH:MM:SSZ`, using uppercase
`T` and `Z`, a real Gregorian UTC date, and no fractional seconds, offsets,
date-only values, or leap seconds. `summary` is one non-empty plain or
double-quoted line of at most 1,024 UTF-8 bytes. A publication timestamp
requires a summary; a summary alone remains valid metadata for future
projections.

An item is eligible only after the shared pipeline validates, when it has both
metadata fields and its status is omitted, `published`, or `archived`. Drafts
are excluded. Items sort by publication timestamp descending and canonical id
ascending; the limit is applied after sorting.

## URLs and XML

`--site-url` is an absolute HTTP(S) URI of at most 2,048 bytes with a non-empty
DNS host or bracketed IPv6 host, an optional decimal port, and no user
credentials, query, or fragment. It is ASCII RFC 3986 syntax: a path may use
unreserved characters, sub-delimiters, `:`, `@`, `/`, and valid percent
escapes; raw spaces, control bytes, non-ASCII bytes, and URI delimiters such as
`<` are rejected. It may include a deployment base path. Channel and item URLs
normalize joining to one slash and use Boris's safe
`{entity-id}.html` output path, percent-encoding path bytes as needed without
escaping the configured base path.

The emitted document contains the XML declaration, RSS 2.0 channel title,
link, description, and current Boris compiler identity as generator. Items
contain title (id fallback), absolute link, permalink GUID, summary,
RFC-822-style GMT `pubDate`, and one category for each tag in source order.
XML text and attributes escape reserved characters and reject XML 1.0-forbidden
control bytes. UTF-8 stays UTF-8; CDATA is not used.

## Determinism and publication

The feed has no current time, build date, filesystem timestamp, Atom self-link,
language, full HTML content, authors, enclosures, comments, images, or custom
extensions. An empty eligible set is a valid feed. The exporter renders and
validates all bytes before safely replacing the relative destination; it creates
parent directories, rejects workspace escape and content-root collisions, and
preserves the existing destination on failure. RSS metadata is intentionally
not added to the base JSON IR in this slice, so existing IR/RAG/Context/HTML
bytes remain unchanged for content that does not use it.
