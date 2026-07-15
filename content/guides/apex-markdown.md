---
title: Apex Markdown Showcase
status: published
tags: [markdown, showcase, apex]
---

# Apex Markdown Showcase

Boris renders page bodies with **ApexMarkdown Unified** (vendored pin) through
an in-process C ABI host adapter — not a toy stub and not a subprocess.

This page is a living testbed for constructs that matter in docs sites.

## Typography

Emphasis, **strong**, and ~~strikethrough~~ work as usual. Smart typography:
"curly quotes", em-dashes --- and ellipses...

Subscript and superscript: H~2~O, e=mc^2^.

## Lists and task lists

1. Discover content
2. Parse frontmatter
   - Resolve graph
   - Validate nodes
3. Render HTML

- [x] Feature 1 — ApexMarkdown Unified
- [x] Feature 2 — HTML default CLI
- [x] Feature 6 — graph-aware nav + in-page TOC
- [x] Feature 7 — includes + wiki-links (pre-Apex on HTML path)
- [x] P2/P3 — incremental, watch, jobs, multi-target

## Math

Inline: $a^2 + b^2 = c^2$.

Block:

$$
f(x) = \int_{-\infty}^\infty \hat f(\xi)\,e^{2 \pi i \xi x} \,d\xi
$$

## Tables

| Feature | Status | Notes |
| :--- | :---: | ---: |
| ApexMarkdown Unified | Yes | In-process C ABI |
| Graph validation | Yes | Trunk / Satellite |
| Nested asides | No | Contract forbids |
| Site nav + TOC | Yes | Layout markers in v0.2 |
| Includes + wiki-links | Yes | Before Apex; fences stay raw |

## Definition lists

Apple
:   Pomaceous fruit of plants of the genus Malus.

Orange
:   Fruit of an evergreen tree of the genus Citrus.

## Autolinks and footnotes

URLs like https://ziglang.org may auto-link depending on engine options.

You can add footnotes for extra context.[^1]

[^1]: Footnote text is rendered with the page body (engine-dependent placement).

## Abbreviations and emoji

The HTML specification is maintained by the W3C.

*[HTML]: HyperText Markup Language
*[W3C]: World Wide Web Consortium

Product callouts use the registered Aside component — not unrestricted MDX. 🎉

## Aside (product component)

<Aside kind="info">

This is Boris’s supported Aside — tips, warnings, and notes that stay in
document order. Full syntax: [[guides/asides|Using Asides]].

</Aside>

Document the tag syntax inside fenced code on the asides page so the tokenizer
does not treat examples as nested components.

For graph structure and closed keys, see [[guides/overview|the content model]]
and [[reference/frontmatter]].
