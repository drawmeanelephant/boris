# Compiler-owned head metadata

**Status:** normative opt-in HTML surface. `build`, `watch`, and zero-write
`validate --profile PATH` use the same target-local resolver and emitter.
No frontmatter or base IR schema changes. No crawler or deployment certification.

## Closed declaration

Each HTML profile target may declare `head` and `html_profile`
(`html`, `xhtml`, or `html4_strict`; omitted means the existing HTML default).
The profile remains schema 1 with additive closed fields. Older profile parsers
reject those fields. A plan containing either field negotiates **plan schema 3**
([schema](schemas/publication-plan-3.schema.json)); other plan bytes stay unchanged,
including schema 2 for an existing NIP-42-only declaration.

```json
{
  "name": "public",
  "output": "dist",
  "public": true,
  "theme": "theme",
  "head": {
    "enabled": true,
    "base_url": "https://owner.github.io/project",
    "ogp": "optional",
    "defaults": {
      "description": "Site description",
      "image": {
        "source": "theme",
        "path": "assets/social.svg",
        "alt": "Site illustration"
      },
      "twitter_card": "summary"
    },
    "pages": [{
      "id": "guides/intro",
      "values": { "title": "Introduction", "type": "article" },
      "modified_time": "2026-10-03T00:00:00Z"
    }]
  }
}
```

`enabled` defaults to false. An enabled declaration requires its **own**
`base_url`, validated and normalized by the existing RSS/sitemap HTTP(S)
grammar. It never inherits another target's base, `site.url`, or publication
location. When this target also emits sitemap/RSS, its base must equal
`site.url`; when a publication location is declared, it must equal that base.

`ogp` is `optional` (default) or `required`. `defaults` and each page's
`values` have exactly the optional fields `title`, `description`, `image`,
`type` (`website`/`article`), and `twitter_card`
(`summary`/`summary_large_image`). An image is a whole object with exactly
`source` (`theme`/`static`/`content`), emitted target-relative `path`, and `alt`.
No external images, body-image inference, favicon inference, canonical
overrides, arbitrary tags, author identity, or metadata passthrough.

`pages` is an exact entity-id override array, sorted by id in the normalized
plan. Duplicate ids, unknown ids, unknown/duplicate keys, wrong types, invalid
UTF-8, control bytes, unsafe paths, invalid enum values and dates fail.
There are at most 256 overrides. Text fields are non-empty and at most
1,024 UTF-8 bytes, image paths at most 1,024 bytes. These are Boris resource
bounds, **not** claims about X-specific limits. The containing profile retains
its existing byte/depth limits.

## Resolution and output

| Field | Precedence, first available wins |
|-------|---------------------------------|
| Title | Exact override, page `title`, target default, entity id |
| Description | Exact override, page `summary`, target default, otherwise omitted |
| Image + alt | Exact whole-object override, target whole-object default, otherwise omitted |
| Type | Exact override, target default, `article` for a page with `published_at`, otherwise `website` |
| Twitter card | Exact override, target default, `summary` |

`summary_large_image` requires a resolved explicit image. No guessed text is
scraped from rendered bodies. Attribute values use the shared XML/HTML-safe
encoder, including quotes, angle brackets and ampersands.

Canonical is `normalized_base + "/" + percent_encoded(emitted_output_path)`,
using the sitemap URL builder and the same path-byte encoding as RSS.
`index` remains `index.html`; nested paths, UTF-8 ids and project bases retain
their exact route policy. Canonical equals `og:url`.

HTML emits canonical, optional description, actual `property="og:*"` tags and
explicit `name="twitter:*"` tags. It does not emit `name="og:*"` aliases.
Article pages emit `article:published_time` when authored `published_at` exists.
They emit `article:modified_time` only when the exact override supplies a valid
strict UTC `modified_time`. Boris currently has **no authored modification-date
frontmatter fact**: it never substitutes a filesystem/build time or the
publication date. Website pages omit article dates.

Strict omits all optional OGP/article property tags with visible `WHEADOGP`,
even under `--quiet`; canonical, description, Twitter and RSS remain valid
Strict tags. `ogp: "required"` fails with `EHEAD` before publication.
XHTML uses self-closing void tags; the existing XML wrapper requirement and
raw-HTML refusal remain unchanged. This is not a new XHTML DTD conformance claim.

Draft HTML receives **none** of these new tags, including RSS autodiscovery.
Existing draft advertising exclusions and emitted routes stay unchanged.
Standard.site and Nostr fragments compose before this fragment, unchanged.

## Assets, layout and publication

Every configured image, even an unused default/override, must occur in the
selected target's matching theme, static or content-local inventory. The
path names the **emitted** asset (for example
`guides/intro.assets/hero.png`), not a workspace/source path.
The existing deterministic image-header probe must recognize nonzero dimensions
(PNG/GIF/JPEG/WebP/BMP/SVG). This is bounded header validation, not full image
decoding, resizing, or crawler-format certification. Existing inventory safety
and SVG policies still apply; asset bytes are never altered.

Every eligible page's selected layout must have exactly one real `{{head}}`
directly inside its actual `<head>`, not inside a comment, attribute, title,
script, or body. Hand-authored canonical, description, OGP, Twitter, article
date and RSS autodiscovery tags conflict with compiler ownership and fail.
The same check rejects such tags in rendered content or emitted footer
fragments. Comments, escaped examples and raw-text strings are not tags.
Structured `EHEAD` diagnostics name the target and selected layout/source.

Configuration, image inventory, layout and feed checks run before target/stage
creation. Rendering checks run before commit. Missing assets and failed
preflight preserve the last-good target. Existing per-file commit limitations
are unchanged; no whole-publication transaction is claimed.
Resolved emitted head bytes join each page's fingerprint. Base, override,
default and profile changes invalidate affected pages; unchanged image bytes
do not alter the HTML URL and need no page render, but asset validity is checked
again even for cached pages. Clean, repeated incremental and bounded parallel
rendering use the same bytes.

## Bounded RSS rider and execution boundary

A **single** profile HTML target with enabled `head` may also execute its existing
`rss: {"path": "feeds/rss.xml", "limit": 20}` declaration. The existing
`public`, `site.url`, `site.title`, and `site.description` requirements remain.
The feed uses the existing RSS renderer, eligibility/order/limit rules and
target staging, and is recorded as an RSS artifact. Its canonical absolute URL
is emitted as `rel="alternate" type="application/rss+xml"` in eligible heads.
RSS path collisions fail preflight; changing/removing a feed removes the prior
inventory-owned feed after a successful commit, without deleting a route now
owned by another producer.

This narrowly enables RSS for this head surface, **not** the full profile
coordinator. RSS without enabled head, multi-target RSS, llms/IR/RAG/Context
profile execution, multi-target sitemap/static/publication metadata, and the
existing watch Standard.site limitation remain refused. Explicit-selector
metadata opt-in does not silently execute `head`/`html_profile`; omit competing
HTML selectors and let the profile select its targets.
Watch retains its startup profile snapshot; restart after profile changes.
Unconfigured/disabled/local builds retain their old page bytes and never
invent a public absolute URL.

Focused evidence: `src/compile_head_test.zig`, `src/head_metadata.zig`,
publication profile/plan tests, and `test/validate-contract.sh`, all under the
existing tests/release gate. A runnable specimen is
[the profile fixture](fixtures/head-metadata/profile.json).
