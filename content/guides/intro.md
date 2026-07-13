---
title: Introduction
---

# Introduction

Boris models content as a **Trunk and Satellite** graph, not a flat folder dump.

Canonical trunks hold the long-form narrative. Satellites attach via
`parent` foreign keys in frontmatter.

<Aside kind="tip" id="006-1">
Always declare `parent` on satellites so the graph linker can attach them.
</Aside>

Continue reading the nested tips for more.

When you are ready to ship project knowledge into a chat LLM, see
[RAG export command](rag-export.md) for `zig build rag` and the corpus layout.
