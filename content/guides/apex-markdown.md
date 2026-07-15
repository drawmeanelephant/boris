---
title: Apex Markdown Showcase
status: published
tags: [markdown, showcase, apex]
---

# Apex Markdown Showcase

Boris renders page bodies with **ApexMarkdown Unified** (vendored pin v1.1.11)
through an in-process C ABI host adapter — not a toy stub and not a subprocess.
This page is a living gallery of constructs that matter on documentation sites.

Product callouts with document-order guarantees use the registered
[[guides/asides|Aside]] component. Apex also supports `> [!NOTE]`-style callouts;
see [Apex callouts](#apex-callouts) for the difference.

## At a glance

| Construct | Jump | Notes |
| :--- | :---: | :--- |
| Emphasis / strong / strike | [Inline](#inline-formatting) | `*`, `**`, `~~` |
| Inline code | [Inline](#inline-formatting) | Single backticks |
| Sub / superscript | [Inline](#inline-formatting) | `H~2~O`, `e=mc^2^` |
| Smart typography | [Inline](#inline-formatting) | Quotes, dashes, ellipses |
| Headings + IAL ids/classes | [Headings](#headings-and-attributes) | `{#id .class}` |
| Nested lists | [Lists](#lists) | Ordered + unordered |
| Task lists | [Task lists](#task-lists) | `- [x]` checkboxes |
| Blockquotes | [Blockquotes](#blockquotes) | `>` |
| Apex callouts | [Callouts](#apex-callouts) | `> [!NOTE]` family |
| Fenced code | [Code](#fenced-code) | Language tags; HTML escaped |
| GFM tables | [Tables](#tables) | Alignment markers |
| Definition lists | [Definition lists](#definition-lists) | Term + colon definition |
| Math | [Math](#math) | `$…$` and `$$…$$` |
| Footnotes | [Footnotes](#footnotes) | Refs mid-page; defs at end |
| Abbreviations | [Abbreviations](#abbreviations-and-emoji) | abbreviation definitions |
| Emoji | [Abbreviations](#abbreviations-and-emoji) | Glyphs and shortcodes |
| Links and images | [Links](#links-and-images) | Inline, autolink, image |
| Horizontal rules | [Breaks](#paragraphs-breaks-and-rules) | `***` / `___` |
| Trusted raw HTML | [Raw HTML](#raw-html-trusted-authors) | Host allows it for authors |
| Fenced divs | [Fenced divs](#fenced-divs) | `::: {.class}` syntax |

## Headings and attributes

Headings feed the in-page TOC when the layout includes the toc marker. Apex
accepts Pandoc-style IAL attributes on the same line as the heading:

```markdown
## Custom heading id {#custom-showcase-id .showcase-heading}
```

## Custom heading id {#custom-showcase-id .showcase-heading}

That heading should carry `id="custom-showcase-id"` and class `showcase-heading`
in the HTML. Use this when you need stable anchors independent of auto-slug
text.

### Level-three section

TOC includes h1–h3 in the default layout. Deeper levels still render; they just
omit from the page outline.

#### Level four (still valid Markdown)

Useful for long reference pages that need extra hierarchy without crowding the
sidebar outline.

## Inline formatting

| Form | Rendered |
|------|----------|
| Emphasis | *italic* and _also italic_ |
| Strong | **bold** and __also bold__ |
| Combined | ***bold italic*** |
| Strikethrough | ~~retired API~~ |
| Inline code | `const x = 1;` |
| Subscript | H~2~O, CO~2~ |
| Superscript | e=mc^2^, 1^st^ place |

Smart typography (engine-dependent): "curly quotes", em-dashes --- en-dashes --
and ellipses...

Hard line break after this sentence (two trailing spaces):  
this line should sit directly under the previous one.

## Paragraphs, breaks, and rules

Paragraphs are separated by blank lines. Multiple spaces collapse in ordinary
prose unless you are inside a code span or fence.

A thematic break follows (asterisk form — prefer this over a lone triple-dash
line after prose, which some engines treat as a setext underline):

***

Underscore form:

___

Use rules sparingly between major blocks; prefer headings for navigation.

## Links and images

- Explicit link: [Zig language site](https://ziglang.org)
- Autolink-style URL: https://ziglang.org
- Inline repo link: [Boris on GitHub](https://github.com/drawmeanelephant/boris)
- Wiki-link (Boris, pre-Apex): [[getting-started|Getting started]]

Images use ordinary Markdown. Prefer local assets under your content tree when
you ship a real site; external URLs work for demos:

```markdown
![Zig logo](https://ziglang.org/img/zig-logo-dark.svg)
```

![Zig logo](https://ziglang.org/img/zig-logo-dark.svg)

## Blockquotes

> Simple pull-quote. Nested formatting works: **strong**, `code`, and
> [links](https://ziglang.org).

> Outer quote
>
> > Nested quote for citation-style layering.
>
> Back to outer.

## Apex callouts

Apex Unified recognizes GitHub-style alert markers inside blockquotes. These
are **engine callouts** (HTML classes like `callout-note`), not Boris graph nodes
and not the registered Aside component.

> [!NOTE]
> Neutral context. Good for “why this exists” asides in long guides.

> [!TIP]
> Prefer closed frontmatter and fail-loud parents. See the
> [[reference/frontmatter|frontmatter reference]].

> [!IMPORTANT]
> Bare `boris` builds HTML under `dist/`. IR needs `--out`; RAG needs `--rag`.

> [!WARNING]
> Mixing IR and HTML mode flags exits **2** (usage). Check
> [[guides/cli-and-modes|CLI and modes]].

> [!CAUTION]
> Intentionally broken parents must not live under `content/` — use fixtures.

Boris product callouts with document-order guarantees use Aside instead. Syntax
(fenced so the tokenizer does not treat this sample as a live component):

```html
<Aside kind="tip">

Actionable advice that stays in the page stream.

</Aside>
```

Live Aside on this page:

<Aside kind="info">

This is Boris’s supported Aside. Full syntax and rules:
[[guides/asides|Using Asides]].

</Aside>

## Lists

Unordered:

- Discover Markdown under `content/`
- Parse closed frontmatter
  - Resolve Trunk / Satellite roles
  - Validate the graph (fail loud)
- Render with Apex, then splice layout chrome

Ordered with nesting:

1. Load content
2. Roll metadata and graph
   1. Frontmatter
   2. Parent edges
3. Ignite HTML (or IR / RAG)
4. Reset page scratch

Tight list (no blank lines between items):

- Tight item one
- Tight item two

Loose list (blank lines between items — items become paragraphs):

- Loose item one

- Loose item two

## Task lists

- [x] Feature 1 — ApexMarkdown Unified
- [x] Feature 2 — HTML default CLI
- [x] Feature 6 — graph-aware nav + in-page TOC
- [x] Feature 7 — includes + wiki-links (pre-Apex)
- [x] P2/P3 — incremental, watch, jobs, multi-target
- [ ] Not product surface — full YAML frontmatter, unrestricted MDX

## Fenced code

Language-tagged fence (no external highlighter process; tags still help CSS or
future host options):

```zig
const std = @import("std");

pub fn main() void {
    std.debug.print("hello from a fence\n", .{});
}
```

HTML and angle brackets inside fences must not break out of pre/code:

```html
<div class="example">1 < 2 && 3 > 0</div>
<script>alert("stays text")</script>
```

Tilde fences are also recognized:

~~~text
tilde fence body
~~~

Indented code (four spaces) is CommonMark-compatible:

    fn indented() void {}

## Tables

GFM pipe tables with column alignment:

| Feature | Status | Alignment demo |
| :--- | :---: | ---: |
| ApexMarkdown Unified | Yes | left / center / right |
| Graph validation | Yes | Trunk / Satellite |
| Nested Asides | No | Contract forbids |
| Site nav + TOC | Yes | Layout markers |
| Includes + wiki-links | Yes | Before Apex; fences stay raw |

Cells may contain *emphasis*, `code`, and [links](https://ziglang.org).

## Definition lists

Trunk
: A top-level page. Omit `parent` in frontmatter.

Satellite
: A direct child of a trunk. Set `parent` to a trunk entity id.

Aside
: Registered callout component. Not a graph node. Stays in document order.

Entity id
: Path without extension by default (`guides/overview.md` becomes `guides/overview`). Same space as `parent` and wiki-link targets.

## Math

Inline: the Pythagorean relation $a^2 + b^2 = c^2$ and Euler’s identity
$e^{i\pi} + 1 = 0$.

Display:

$$
f(x) = \int_{-\infty}^{\infty} \hat{f}(\xi)\, e^{2\pi i \xi x}\, d\xi
$$

$$
\begin{aligned}
\nabla \cdot \mathbf{E} &= \frac{\rho}{\varepsilon_0} \\
\nabla \cdot \mathbf{B} &= 0
\end{aligned}
$$

Apex emits KaTeX-style delimiters in HTML spans. Whether glyphs paint depends
on whether your layout loads a math stylesheet or runtime — the markup is still
present for site authors who wire CSS.

## Footnotes

Docs often need side notes without breaking the main sentence flow. Apex
supports footnote references and hoists definitions into a footnotes section
with back-refs.[^syntax] Keep labels unique for clarity.[^second]

Put footnote *definitions* at the **end of the page** (after all other
sections). Mid-document definitions can swallow following headings.

## Abbreviations and emoji

Abbreviations expand on hover when the engine emits abbreviation markup. The
GFM table and CLI examples on this site are good places to see short forms in
context.

*[GFM]: GitHub Flavored Markdown
*[CLI]: Command-Line Interface
*[TOC]: Table of Contents
*[IAL]: Inline Attribute List

Emoji shortcodes and literal glyphs (engine-dependent): :tada: :zap: :books:
🎉 ⚡ 📚

Product callouts still prefer Aside over ad-hoc emoji-only signaling.

## Raw HTML (trusted authors)

The host adapter allows raw HTML for **trusted author content**. Keep it small;
prefer Markdown so TOC, footnotes, and Apex features stay predictable.

Example (shown fenced so surrounding sections stay clean in the showcase):

```html
<p class="showcase-raw"><em>Raw</em> HTML paragraph for CSS hooks.</p>
```

Do **not** treat this as a green light for unrestricted MDX or executable
components. PascalCase tags other than Aside still fail component tokenization.
Lowercase HTML such as `p`, `div`, and `span` may pass through to Apex when used
sparingly in real pages.

## What Boris adds outside Apex

These are **not** Apex features; they run (or apply) around the engine:

| Feature | Where |
|---------|--------|
| Closed frontmatter | Before graph validation — [[reference/frontmatter]] |
| Trunk / Satellite graph | Fail-loud parents — [[guides/trunk-satellite]] |
| Include directives | Zig expand before Apex (HTML path) |
| Wiki-links by entity id | Zig rewrite before Apex (HTML path) |
| Aside components | Tokenize around Apex markdown segments |
| Layout nav / toc markers | After body HTML is produced |

Fenced examples of includes and wiki-links stay literal (correct fence
behavior). Live forms appear on [[getting-started]] and [[guides/overview]].

## What is deliberately not product surface

| Idea | Why |
|------|-----|
| Apex file includes | Off; Boris owns includes |
| External highlighters / plugins | No subprocess markdown tools |
| Full YAML frontmatter | Closed keys only |
| Unrestricted MDX / JS expressions | Aside registry only |
| Nested Asides | Contract forbids |

## See also

- [[guides/asides|Using Asides]] — product callouts
- [[guides/overview|Content model]] — pipeline and graph
- [[guides/cli-and-modes|CLI and modes]] — HTML / IR / RAG
- [[reference/frontmatter|Frontmatter reference]] — closed author keys

## Fenced divs

Apex Unified supports Pandoc-style fenced divs: a line of three colons with a
brace-class attribute, a body, and a closing line of three colons. The engine
emits a `div` with that class (covered by host fidelity tests). Prefer
[[guides/asides|Aside]] for product callouts with diagnostics — on long pages,
live `:::` blocks can interact poorly with following headings, so this showcase
documents the feature without stacking one after every other demo.

[^syntax]: Footnote definition lines use a caret label and a colon, then the note body. Apex hoists them into a footnotes list with back-refs.
[^second]: Second note to demonstrate ordered footnote lists and back-refs.
