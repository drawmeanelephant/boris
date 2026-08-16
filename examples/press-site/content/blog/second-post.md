---
title: The graph is the index
parent: blog
status: published
tags: [journal, graph]
---

# The graph is the index

The most important difference from a legacy template is that navigation is no
longer a hand-authored list pretending to know the site. Boris has the graph;
the theme gives its output a place to belong.

> A good archive does not merely remember pages. It remembers how to reach
> them.

The blog landing page uses `{{children}}`, while the masthead and rail use
`{{nav}}`. Those are two views of the same validated graph.
