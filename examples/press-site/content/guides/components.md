---
title: Components and content
parent: guides
status: published
tags: [guides, markdown, components]
---

# Components and content

The port is intentionally content-first. CommonMark prose gets editorial
typography, while Boris's closed components receive clear edges and labels.

## Callouts

<Aside kind="info">

Use an `Aside` when the reader should see the supporting thought immediately.
The theme keeps the kind label in the rendered component so meaning is not
carried by a color alone.

</Aside>

## Disclosures

<Details summary="A native Details panel" id="native-details">

Use `Details` for optional depth, a long note, or an authoring aside that
should not interrupt the first read. The browser supplies the disclosure
interaction and keyboard behavior.

</Details>

## Ordinary Markdown still matters

1. Headings become the page outline.
2. Tables support comparisons.
3. Fenced code keeps commands copyable.

```css
.txp-article-content {
  max-inline-size: 46rem;
  margin-inline: auto;
}
```

> A theme is successful when the author can forget the theme while writing.
