---
title: Trunk & Satellite — Content Hierarchy
parent: guides/overview
status: published
tags: [guides, graph, hierarchy]
---

<p class="eyebrow">Graph</p>

# Trunk & Satellite — Content Hierarchy {#trunk-satellite}

The `parent` field gives Boris an explicit site hierarchy. It is a graph edge,
not a display label or a directory convention. Hosted targets and machine
projections consume the same frozen hierarchy — see
[[guides/publishing|Publishing Workflows]].

<Aside kind="note">

Directory layout is a convenience for humans. Navigation is not inferred
from folders. If you wanted implicit hierarchy, you wanted a different
compiler.

</Aside>

## The two roles

Trunk
: A page with no `parent`. It is a root of the validated hierarchy.

Satellite
: A page with one direct `parent` entity id. Its parent may be a Trunk or
  another Satellite.

For example, `content/guides/building-pages.md` normally has entity id
`guides/building-pages`, while `content/getting-started.md` has entity id
`getting-started`.

## Declare a parent

```markdown
---
title: Advanced Configuration
parent: getting-started
status: published
---
```

Boris checks that the parent exists, rejects self-parenting and cycles, and
freezes the complete finite chain before output publication. There is no
one-level nesting limit.

```text
index (Trunk)
  guides (Satellite)
    guides/overview (Satellite)
      guides/building-pages (Satellite)
```

The default HTML layout uses the graph for its navigation tree and breadcrumbs.
Asides and Details stay in page order; they are not graph nodes.

## Validation and analysis are different

Use the compiler's no-publication HTML preflight when you need an authoritative
validity answer:

```bash
./zig-out/bin/boris validate --quiet
```

Use Documentation Intelligence when you want graph-health facts or impact:

```bash
./zig-out/bin/boris check --format json --report health.json
./zig-out/bin/boris impact guides/overview
```

`check` and `impact` consume a valid frozen graph and analyze parent/include/
reference dependencies. They do not validate layouts, themes, assets, or the
complete HTML render path, and semantic `relations` are a separate metadata
surface.

## Repairing hierarchy changes

When moving a page, update the `parent` value and any wiki-links that should
follow it, then run `validate` and a normal build. `impact ID` is useful before a
large rename because it lists transitive dependents without rewriting source.

<Details summary="What is not a graph node">

`&lt;Aside&gt;` and `&lt;Details&gt;` stay in document order. They do not
get entity ids, parents, or nav entries. A callout is not a page.

</Details>

See [[reference/relationships|Relationships]] for parent edges, wiki-links,
includes, and semantic relations as separate concepts.
