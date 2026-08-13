---
title: Markdown Showcase
parent: guides/overview
status: published
tags: [markdown, showcase, oliver]
---

# Markdown Showcase

Boris renders page bodies with **Oliver**, a freestanding Zig markup library
pinned by content hash in `build.zig.zon` and consumed natively through
`src/render.zig` — never a subprocess, never a shell-out to a CLI. Oliver is
byte-exact CommonMark 0.31.2 plus GFM tables, with the extensions Boris
publishes enabled: heading auto-ids, heading attribute lists, footnotes,
definition lists, and strikethrough.

This page is a living gallery of the constructs that matter on documentation
sites.

Product callouts with document-order guarantees use the constrained
[[guides/asides|Aside]] component. Boris also supports constrained
`&lt;Details&gt;` disclosures. `> [!NOTE]`-style lines are **not** callouts in
Boris — they render as ordinary blockquotes (see
[what is not rendered](#what-is-not-rendered)).

## Feature support at a glance

| Construct | Support | Jump |
| :--- | :---: | :--- |
| ATX and Setext headings with auto-ids | Supported | [Headings](#headings) |
| Heading attribute lists (`{#id .class}`) | Supported | [Headings](#headings) |
| Inline formatting (emphasis, strong, code) | Supported | [Inline formatting](#inline-formatting) |
| Links and images (inline + reference) | Supported | [Links and images](#links-and-images) |
| Wiki-links (`[[entity-id]]`) | Product Core | [Wiki-links](#wiki-links) |
| Transclusion includes (`{{include path}}`) | Product Core | [Includes](#transclusion-includes) |
| Code (fenced + indented) | Supported | [Fenced code](#fenced-code) |
| Block quotes | Supported | [Block quotes](#block-quotes) |
| Ordered / unordered / nested lists | Supported | [Lists](#lists) |
| Tables (GFM) | Supported | [Tables](#tables) |
| Footnotes (`[^label]` + definitions) | Supported | [Footnotes](#footnotes) |
| Definition lists (`Term` + `: def`) | Supported | [Definition lists](#definition-lists) |
| GFM strikethrough (`~~text~~`) | Supported | [Inline formatting](#inline-formatting) |
| Thematic breaks, autolinks, entities, escapes | Supported | [Paragraphs, breaks, and rules](#paragraphs-breaks-and-rules) |
| Raw HTML (trusted authors) | Supported | [Raw HTML](#raw-html-trusted-authors) |
| Math, callouts, task lists, fenced divs | Not rendered | [What is not rendered](#what-is-not-rendered) |

## Headings

Headings feed the in-page TOC when the layout includes the toc marker. Every
heading gets a deterministic auto-id from its plain text (GFM style: ASCII
lowercase, punctuation and non-ASCII dropped, whitespace runs become `-`).
Duplicate headings share the same id — Boris does not add `-1`/`-2` suffixes.
See [heading IDs and wiki fragments](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/heading-ids.md).

```markdown
## Custom heading id {#custom-showcase-id .showcase-heading}
```

## Custom heading id {#custom-showcase-id .showcase-heading}

That heading carries `id="custom-showcase-id"` and class `showcase-heading` in
the HTML — a heading attribute list overrides the auto slug. Use it for stable
anchors independent of auto-slug text.

### Level-three section

Auto-ids come from the rendered heading, including inline content:

```markdown
### Code `span` and **bold** text
```

### Code `span` and **bold** text

The id is `code-span-and-bold-text`; the heading text keeps its inline markup.

## Inline formatting

CommonMark inline constructs render as expected:

```markdown
*italic* and **strong** and ***both***, `code`, and ~~struck text~~.
```

*italic* and **strong** and ***both***, `code`, and ~~struck text~~.

GFM strikethrough (two tildes) renders as `<del>`; a single `~` or a run of
three or more tildes stays literal.

Backslash escapes and entity references are literal:

- `\*not emphasis\*`
- `AT&amp;T` renders as AT&amp;T

## Paragraphs, breaks, and rules

Consecutive lines without a blank line form one paragraph; soft breaks render
as line breaks inside it. Two spaces at the end of a line (or a backslash)
force a hard break.

A thematic break is three or more `-`, `*`, or `_` on their own line:

---

Autolinks are written as bare URLs or `<...>`:

- https://example.com
- <mailto:hello@example.com>

## Links and images

Standard Markdown links (inline and reference) and images (inline and
reference) are supported. Link destinations are emitted as-is with HTML
escaping; Boris rewrites graph-backed documentation links and content-local
image destinations before rendering (see
[[guides/building-pages|Building Pages]]).

```markdown
[Inline link](https://example.com "title")
[Reference][ref]
![Alt text](image.png)
```

### Wiki-links (`[[entity-id]]`) {#wiki-links}

Boris rewrites wiki-links to relative page links before rendering. A heading
fragment must match a rendered heading id on the target page:

```markdown
[[guides/overview]]
[[guides/overview|Display label]]
[[guides/overview#headings|Headings section]]
```

See [[guides/building-pages|Building Pages]] for the full syntax and error
codes.

## Block quotes

```markdown
> Block quotes are CommonMark block quotes.
>
> > They nest.
```

## Lists

Ordered and unordered lists nest and render as tight or loose lists per
CommonMark:

```markdown
- one
  - nested
- two

1. first
2. second
```

Task lists (`- [ ]`) are **not** rendered as checkboxes — see
[what is not rendered](#what-is-not-rendered).

## Fenced code

Fenced code blocks keep their content verbatim and escape angle brackets.
Oliver emits the CommonMark-recommended `class="language-…"` form:

```markdown
```zig
const answer = 42;
```
```

```zig
const answer = 42;
```

Indented code (four spaces) also renders as a `<pre><code>` block without a
language class.

## Tables

GFM tables are supported with alignment:

```markdown
| Left | Center | Right |
| :--- | :----: | ----: |
| a    |   b    |    c  |
```

| Left | Center | Right |
| :--- | :----: | ----: |
| a    |   b    |    c  |

## Footnotes

Footnote references and definitions render with back-references:

```markdown
Boris renders Markdown natively.[^native]

[^native]: The Oliver library parses and renders in-process; no subprocess.
```

Boris renders Markdown natively.[^native]

[^native]: The Oliver library parses and renders in-process; no subprocess.

References are numbered in first-use order; the footnote section is appended at
the end of the page body. Footnote references inside definition-list bodies
render correctly.

## Definition lists

A term paragraph followed by `:` definition lines renders as a definition
list:

```markdown
Trunk
: A page with no direct parent; the root of a navigation branch.

Satellite
: A page with exactly one direct parent.
```

Trunk
: A page with no direct parent; the root of a navigation branch.

Satellite
: A page with exactly one direct parent.

## Transclusion Includes (`{{include path}}`) {#transclusion-includes}

Includes are Boris-mediated and resolved **before** rendering — the renderer
never reads files:

```markdown
{{include includes/shared-tip.md}}
```

See [[guides/building-pages|Building Pages]] for include rules and cycle
diagnostics.

## Raw HTML (trusted authors)

Raw inline HTML and HTML blocks pass through unescaped. Boris assumes trusted
author content — it does **not** sanitize. Fenced code is always escaped.

```html
<details>
<summary>Why does this matter?</summary>
Content inside a raw HTML block.
</details>
```

## What is not rendered

The following constructs are **not** part of Boris's Markdown surface. If a
source line uses them, Oliver treats it as ordinary text (block quotes keep
the `>` marker and `[!NOTE]` text; math stays literal):

- Math (`$x$`, `$$x$$`)
- Callouts (`> [!NOTE]` and Python-Markdown `!!!`)
- Task lists (`- [ ]`)
- Fenced divs (`:::`)
- Bracketed spans (`[text]{ial}`)
- Critic markup (`{++…++}`, `{--…--}`, `{~~…~>…~~}`)
- Smart typography (apostrophes and quotes stay as authored)
- Abbreviations, citations, indices, TOC markers, metadata variables, and
  engine-side file includes

Prefer the Boris-native equivalents: `&lt;Aside&gt;`/`&lt;Details&gt;`
components for callouts, `{{include}}` for includes, and wiki-links for
internal references. See the [renderer contract](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/oliver-renderer.md)
for the full compatibility classification.

## See also

- [[guides/asides|Aside components and admonitions]]
- [[guides/building-pages|Building Pages]] — frontmatter, links, includes
- [[guides/search-and-ui|Search and UI]]
- [Renderer contract](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/oliver-renderer.md)
