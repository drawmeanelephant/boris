---
title: Content Model & Pipeline
parent: guides
status: published
tags: [guides, architecture, pipeline]
---

# Content Model & Pipeline

Boris treats documentation as a validated graph rather than an unrelated pile
of Markdown files. You declare page identity and hierarchy in frontmatter;
Boris resolves that structure before it publishes HTML or a machine projection.

<Aside kind="info">

The useful mental model is: **source pages become a frozen graph, then a
selected output is produced from that graph**. `validate`, `check`, `build`,
and the export modes share the compiler's authorities but answer different
questions. See the [[reference/commands|command reference]] for the exact
routing.

</Aside>

## Pages, Trunks, and Satellites

Every discovered `.md` or `.mdx` page gets an entity id from its
content-root-relative path unless frontmatter supplies an `id`. A page without `parent` is
a **Trunk**. A page with `parent: <entity-id>` is a **Satellite** of that direct
parent.

Satellites may have their own Satellites, so a hierarchy can be arbitrarily
deep as long as every parent exists and the complete graph is acyclic.

```markdown
---
title: A nested guide
parent: guides/overview
status: published
tags: [guides]
---
```

The HTML layout derives navigation and breadcrumbs from this frozen hierarchy.
The graph rules and dependency edge vocabulary are normative in the
[[reference/relationships|relationships reference]] and the repository's
[IR contract](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/ir-schema.md).

## References and reusable fragments

Use a Boris wiki-link when you want a graph-checked link to another page:

```markdown
See [[guides/building-pages|Building Pages]] for authoring details.
```

The HTML path also accepts heading fragments such as
`[[reference/commands#exit-codes|exit codes]]`; the fragment must match an id
from the target page's rendered headings. Ordinary external Markdown links are
left as links and are not a complete site-wide checker.

Reusable source fragments live under `content/includes/`:

```markdown
{{include includes/shared-tip.md}}
```

The include expands in place before Markdown rendering. The `includes/` tree is
not discovered as a page tree; missing targets and cycles fail loudly. Syntax
inside fenced code remains literal.

## What the compiler does

The shared authority sequence is easier to understand as four responsibilities:

1. **Discover and parse.** Find the selected input family, parse the closed
   frontmatter grammar, and promote page metadata.
2. **Validate and freeze.** Resolve ids, parent chains, semantic relations,
   components, and include/wiki dependencies into a valid graph.
3. **Prepare the selected output.** For HTML, load layouts and assets, harvest
   headings, render with Oliver, and prepare navigation/chrome. Other commands
   select IR, RAG, Context, `llms.txt`, RSS, or sitemap rules.
4. **Act on the command.** `validate` discards prepared bytes; `build` stages
   and commits its publication; analysis commands report graph facts; export
   commands stage their own projection.

This is why a successful `validate` proves source/configuration prepublication
validity but does not prove a later output write, deployment, accessibility, or
prose-quality result. The exact boundary is in the
[validation contract](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/validation.md).

## Same source, separate projections

HTML, JSON IR, RAG, Context, `llms.txt`, RSS, and HTML sitemap output are not one
opaque multi-writer artifact. Run the desired commands against the same source
revision when you need aligned outputs. [[guides/rag-export|AI & Machine Outputs]]
covers the machine projections; [[guides/search-and-ui|Search & Browser UI]]
covers the compiler-owned rendered-search artifact.

## Next steps

- [[guides/building-pages|Building Pages]] — create and link pages.
- [[guides/trunk-satellite|Trunk & Satellite]] — inspect hierarchy rules.
- [[guides/themes-and-layouts|Themes & Layouts]] — select layouts and assets.
- [[reference/diagnostics|Diagnostics]] — understand failure categories.
