---
title: Apex Markdown Showcase
status: published
tags: [markdown, showcase, apex]
---
# Apex Markdown Showcase

Boris uses **ApexMarkdown Unified**, a C ABI host adapter that supports an incredibly rich feature set out of the box. This page serves as a testbed and showcase for these features.

## Smart Typography and Formatting

We support standard emphasis, **strong text**, and ~~strikethrough~~.
But we also have smart typography: "curly quotes", em-dashes --- and ellipses...

You can also use H~2~O for subscript and e=mc^2^ for superscript.

## Lists and Task Lists

1. Discover content
2. Parse frontmatter
   - Resolve graph
   - Validate nodes
3. Render HTML

- [x] Feature 1 (Engine)
- [x] Feature 2 (CLI)
- [ ] Feature 6 (Graph Nav)

## Math Support

Inline math is easy: $a^2 + b^2 = c^2$.

Block math uses double dollars:

$$
f(x) = \int_{-\infty}^\infty \hat f(\xi)\,e^{2 \pi i \xi x} \,d\xi
$$

## Tables and Data

### Standard GFM Table

| Feature | Status | Notes |
| :--- | :---: | ---: |
| Apex Markdown | ✅ | C ABI Adapter |
| Graph Validation | ✅ | Trunk/Satellite |
| Nested Asides | ❌ | Banned by contract |

### Grid Tables (if enabled)

+---------------+---------------+--------------------+
| Fruit         | Price         | Advantages         |
+===============+===============+====================+
| Bananas       | $1.34         | - built-in wrapper |
|               |               | - bright color     |
+---------------+---------------+--------------------+
| Oranges       | $2.10         | - cures scurvy     |
|               |               | - tasty            |
+---------------+---------------+--------------------+

## Definition Lists

Apple
:   Pomaceous fruit of plants of the genus Malus in
    the family Rosaceae.

Orange
:   The fruit of an evergreen tree of the genus Citrus.

## Autolinks and Footnotes

Emails like team@boris-ssg.example.com and URLs like https://ziglang.org auto-link!

You can add footnotes for extra context.[^1]

[^1]: This is the footnote text, rendered at the bottom of the page.

## Abbreviations, Emoji, and Callouts

The HTML specification is maintained by the W3C.

*[HTML]: Hyper Text Markup Language
*[W3C]: World Wide Web Consortium

I love using Boris! 🎉 It is incredibly fast 🚀.

### Custom component: Aside

<Aside kind="info">

This is Boris’s officially supported Aside component — use it for tips, warnings, and other callouts that should stay in document order.

</Aside>

Examples of the tag syntax belong in fenced code on the [Asides](asides.html) guide so the tokenizer does not treat documentation as nested components.

## Images with Captions

![A scenic view of the Zig language logo in the wild](/assets/zig-logo.png "Zig Logo")

*Note: You'll need actual images to see them!*
