# Graph-backed Markdown documentation links

**Status:** normative HTML first slice — pre-Apex, afterparty
**Modules:** [`src/doclink.zig`](../../src/doclink.zig), [`src/html_body.zig`](../../src/html_body.zig)
**Related:** [html-output.md](html-output.md), [identity-and-paths.md](identity-and-paths.md), [frontmatter.md](frontmatter.md)

## Purpose

Boris may make author-facing links to discovered Markdown pages pleasant in the
published HTML without changing the renderer core. The first slice rewrites
recognized inline Markdown links before Apex, using the frozen page graph and
the existing canonical output-path functions.

This is a rendered-HTML convenience only. It does not create graph edges,
change RAG/search data, or invent pages for missing targets.

## Rewrite boundary

The rewriter operates on structured inline Markdown link destinations. It is
not an HTML string substitution pass. It runs on the root page body before
include expansion, component tokenization, and Apex rendering. That ordering
keeps relative paths anchored to the page that authored them.

The first slice rewrites links in the root page body. Links introduced by an
`{{include …}}` fragment retain their fragment-local source context only in the
include subsystem and are therefore left unchanged until a provenance-aware
include rewrite is designed.

## Recognized links

Only inline Markdown links with a destination path ending in lowercase `.md`
or `.mdx` are candidates:

```markdown
[Guide](../guide.md)
[Install](/docs/install.md?view=all#setup)
```

Relative paths resolve from the source page's content-root-relative directory.
One leading `/` resolves from the content root. The resolved source path must
match an existing graph node's `source_path` exactly. A matching node's
`entity_id` is converted with `identity.htmlOutputPath`, then
`identity.relativeHref` produces the page-relative public href. Query strings
and fragments are copied verbatim.

Boris's current output contract is `{entity_id}.html`; there is no directory
`index.html` → directory-URL mapping in this slice.

## Unchanged inputs

The following remain byte-for-byte unchanged:

- external URLs with a scheme, protocol-relative URLs, `mailto:` and `tel:`;
- image links, raw HTML tags/attributes, code spans, and fenced code;
- fragment-only/query-only destinations;
- non-Markdown files and uppercase/noncanonical extensions;
- missing graph targets;
- lexical or percent-encoded traversal, backslashes, malformed escapes, and
  paths that leave the content root;
- reference-style links and other forms outside the first inline-link parser.

There is no frontmatter opt-out key in this slice. The closed frontmatter
grammar remains unchanged, and absence of a policy field is the compatible
default.

## Safety and determinism

Public hrefs are built only from validated graph entity IDs and the canonical
URL-relative helper. The resolver never joins a public href as a filesystem
path. Traversal is rejected before graph lookup, including decoded dot/slash
escapes; rejected candidates remain literal. Output depends only on the body,
source/output paths, and frozen node order/content, and does not mutate the
graph.

Focused unit and HTML integration tests cover nested and root-relative links,
query/fragment preservation, titles and angle destinations, escaping,
exclusions, code/fence/raw-HTML boundaries, missing targets, and traversal.
