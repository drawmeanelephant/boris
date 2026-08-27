---
title: Graph panel
status: published
parent: notes
tags: [graph]
relations: [depends_on=search]
---

# Graph panel

Every page ends with a three-block panel: relations, children, and
backlinks. Blocks with nothing to show collapse away, so a leaf page stays
quiet.

This page declares `depends_on=search`, so its relations block renders the
outgoing edge and the [[search|Search]] page gains a backlink.
Children of [[notes|Notes]] appear on the trunk page, not here.

> [!DANGER]
> Relations are validated against the graph before publication. A relation
> naming a missing page fails the build loudly — the panel never renders an
> invented link.
