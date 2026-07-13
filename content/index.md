---
title: Home
---

# Welcome to Boris

This site was compiled by **Boris**, a standalone Zig static site generator.

It walks `content/` once, parses Trunk/Satellite relations, renders markdown
through the native Apex C-ABI engine (including in-page asides/admonitions),
and streams HTML with zero-copy layout splicing.

## Guides

- [Introduction](guides/intro.md) — Trunk and Satellite content model
- [RAG export command](guides/rag-export.md) — export an LLM knowledge corpus with `zig build rag`
