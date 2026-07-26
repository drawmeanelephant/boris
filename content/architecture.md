---
title: Architecture
parent: index
status: published
tags: [architecture, compiler]
---

# Architecture

Boris is a small compiler with explicit seams. This section is for readers who
want to understand why the workflow is shaped this way, not just which command
to type.

| Question | Page |
|---|---|
| How does a page become a site? | [[guides/overview|Content Model Overview]] and [[contest/the-pipeline|The output pipeline]] |
| Why are parent edges explicit? | [[guides/trunk-satellite|Trunk and Satellite Pages]] |
| How does Boris support AI grounding? | [[guides/rag-export|RAG Export Packaging]] |
| What does the compiler deliberately refuse? | [[contest/what-we-cut|What Boris cuts on purpose]] |

The north star is simple: discover, validate, emit, and reset. The compiler
stays native and deterministic so the generated site remains understandable
after the build is over.
