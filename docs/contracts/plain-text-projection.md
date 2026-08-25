# Semantic plain-text projection contract

**Status:** normative — the deterministic semantic plain-text projection over
the Oliver typed document is implemented and wired into Standard.site
`textContent`. This is the optional quality follow-up from #452; metadata-only
Standard.site documents remain valid without it.

**Module:** [`src/render.zig`](../../src/render.zig) (`renderPlainText`),
[`src/html_body.zig`](../../src/html_body.zig) (`renderSourcePlainText`),
[`src/aside.zig`](../../src/aside.zig) (`renderPlainText` /
`renderDetailsPlainText`).  \
**Related:** [oliver-renderer.md](oliver-renderer.md),
[standard-site.md](standard-site.md),
[atproto-live-smoke.md](atproto-live-smoke.md)

## Goal

Expose a useful, deterministic plain-text view of authored documents so
Standard.site can populate `textContent` without stripping Markdown or rendered
HTML. The projection keeps the author's words and drops presentation-only
markup. It is one of four distinct representations, never a substitute for the
others:

1. source Markdown/Textile/Cooklang bytes,
2. rendered HTML,
3. **semantic plain text** (this contract),
4. future protocol-specific rich content.

## Boundary and ownership

The projection walks Oliver's normalized typed document — the same document the
HTML renderer consumes. Boris does **not** parse Markdown again, does **not**
regex-strip HTML, and does **not** invent a second rendering pipeline. The
preprocessing (frontmatter, input adaptation, include expansion, wiki-link and
documentation-link rewrite, content-local image rewrite, Aside tokenization) is
shared verbatim with the HTML body path in `html_body.zig`; only the final
segment renderer differs.

`src/render.zig` remains Boris's only Oliver integration seam. The tree walk
lives there because it must see Oliver's `Tag`/`Data` union; `html_body.zig`
and `aside.zig` call it and never touch Oliver's types directly.

## Output grammar (fixed policy)

Line endings are LF throughout. Blocks at the same level are separated by one
blank line; the document ends with exactly one LF. Empty input yields empty
output.

| Construct | Projection |
|-----------|------------|
| Heading (1–6) | Inline text on its own line. No `#`, no level marker. |
| Paragraph | Inline text. |
| Thematic break | Dropped (no author text). |
| Fenced / indented code | `content` verbatim, LF-normalized by Oliver, flush-left (never indented, regardless of nesting). |
| HTML block | Dropped (markup). |
| Block quote | Child blocks' text. No `>` marker. |
| Unordered list | `• ` per item; nested lists indent two spaces per level. |
| Ordered list | `N. ` per item, `N` starting from the list's declared start. |
| Definition list | Term on its own line; definition bodies indented two spaces. |
| Table | One row per line; cells joined by a single tab (`\t`). Header row included as the first line. |
| Footnote reference | Dropped from the body; definitions appended after the body in definition order as `label: text`. |

Inline constructs:

| Construct | Projection |
|-----------|------------|
| Text / code span | Verbatim text. |
| Soft break | Space. |
| Hard break | Newline. |
| Emphasis / strong / bold / italic / deleted / inserted / superscript / subscript / cite / span | Child text only. |
| Link | Link label (children), never the destination. |
| Image | Alt text (empty when absent). |
| Autolink | Label (the raw content). |
| Acronym | The letters (the definition title is presentation). |
| Raw HTML / footnote ref | Dropped. |

Asides (`<Aside>`) and Details (`<Details>`) render their inner body text; the
admonition kind, id, and summary chrome are presentation and do not survive,
except a Details summary, which is emitted as a leading line of text (it is
author prose, not markup).

## Whitespace and newline policy

1. All line endings are LF; no `\r` survives.
2. Blocks are separated by exactly one blank line; within a list item or table
   the separator is a single LF.
3. Fenced code content is emitted verbatim with its interior blank lines
   preserved. A trailing blank line *inside* a final fenced block, and a code
   block's terminal newline, are normalized as block separators — the document
   ends with one LF. Interior lines are never altered.
4. No trailing whitespace is emitted on any non-code line.
5. Segment joins (markdown ↔ aside ↔ details) insert one blank line between
   non-empty segments; the accumulated output ends with one LF.

## Integration and bounds

`runStandardSitePublish` renders each page's plain text through
`renderSourcePlainText` and sets `PageInput.text_content` only when the
projection succeeds and `0 < len ≤ 256 KiB`
(`standard_site.max_text_content_bytes`). On any render failure, an empty
result, or a bound violation, `textContent` is **omitted** from the record —
Boris never substitutes raw source or rendered HTML, and never fails the whole
publish over a text projection. `textContent` is excluded by default from the
verification surfaces and the live smoke, which publish metadata-first.

The `documentPayload` key order and the existing `text_content_sha256` digest
are unchanged; only the producer of `text_content` is new.

## Test and acceptance surface

```text
zig build test-render
```

Golden tests pin byte-exact output for headings, paragraphs, emphasis, links,
images, autolinks, code spans and blocks, ordered/unordered/nested lists,
tables, block quotes, thematic breaks, footnotes, definition lists, hard/soft
breaks, raw HTML (block and inline), Unicode, empty documents, and determinism
(dual render). `html_body.zig` pins the cross-segment case (markdown + Aside +
Details + includes + wiki links) and `aside.zig` pins the admonition/Details
plain-text renderers. The full suite (`zig build test`) and the release gate
must stay green; existing HTML output remains byte-identical because the HTML
path is untouched.

## Non-goals

- XHTML output.
- Rich-text or Lexicon content unions.
- Search indexing or summarization.
- Protocol publication logic inside Oliver.
- A universal document converter.
- Altering the HTML renderer's output in any way.
