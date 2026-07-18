---
title: Build guides
status: published
tags: [guides, authoring]
---

# Build guides

The guide section is a Trunk with a Satellite page. Its direct children are
rendered by `{{children}}` in the layout, while the global tree is rendered by
`{{nav}}`.

## Reading the page

The left rail is navigation, the center is the document, and the right rail is
the current page outline. At narrow widths those rails become simple blocks
above and below the article so no information depends on hover or JavaScript.

<Aside kind="note">

All visible chrome is static HTML. Boris resolves the slots during compilation;
the browser only needs to render the resulting files.

</Aside>
