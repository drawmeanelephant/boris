---
title: The output pipeline
parent: contest
status: published
tags: [build-week, pipeline, outputs]
---

# The output pipeline

One Boris content tree is a graph of Markdown pages, not a different source
format for every audience. The compiler reads it once per requested mode and
makes each output boundary explicit.

```text
Markdown + closed frontmatter
          │
          ▼
discover → validate graph → render
          │
          ├── HTML site         (default: dist/)
          ├── JSON IR           (--out .boris)
          ├── RAG corpus        (--rag)
          ├── Context Bundle    (--context)
          └── llms.txt map      (--llms)
```

## The smallest useful run

```bash
zig build
./zig-out/bin/boris --quiet
open dist/index.html
```

That emits a static site from the repository’s own `content/` tree. The same
tree includes this page, [[agents|the agent stories]], normal docs pages,
includes, wiki-links, parent/child navigation, Asides, and Details.

## Preview the Build Week field guide

The repository includes a zero-dependency Field Guide theme that makes this
section and the agent stories ready to browse as a cohesive static demo:

```bash
./zig-out/bin/boris --theme examples/agent-themes/chota/theme --quiet
open dist/contest.html
```

That command uses the same source tree and compiler path as the default build;
it only selects a different static layout and stylesheet. No client framework,
CDN, or deployment service is required to inspect the result locally.

## Why separate outputs matter

HTML is for readers. JSON IR is for inspection and integration. RAG and Context
Bundles are for retrieval and grounded AI workflows. Keeping them separate
prevents one convenience format from quietly becoming another system’s source
of truth.

The output modes also make review concrete: a person can open `dist/`, inspect
the IR, or hand a bounded context bundle to an LLM without asking it to infer
the site’s structure from rendered DOM alone.

See [[guides/rag-export|RAG export]],
[[guides/trunk-satellite|Trunk/Satellite navigation]], and
[[guides/asides|Asides]] for the author-facing details.
