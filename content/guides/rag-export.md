---
title: AI & Machine Outputs
parent: guides/overview
status: published
tags: [guides, rag, ai, ir, llms]
summary: Machine projections share the frozen graph with HTML. They are separate invocations, not a second content model.
---

<p class="eyebrow">Projections</p>

# AI & Machine Outputs {#machine-outputs}

HTML `dist/` is the default target. These commands are **other exits** from
the same frozen graph — not a scrape of the HTML, and not a second authoring
model.

<Aside kind="info" id="same-revision">

Generate the editions from the same source revision when you need them
aligned. Emitting RAG does not prove IR, and neither proves a live deploy.

</Aside>

## What to run {#what-to-run}

| Projection | Flag | Default tree | Consumer |
| :--- | :--- | :--- | :--- |
| JSON IR | `--out DIR` | `.boris/` | Tools, graph inspect |
| Working RAG | `--rag` | `rag/` | Bounded LLM uploads |
| Complete RAG | `--rag --complete` | `rag/` | Full-corpus retrieval |
| Context Bundle | `--context` | `context/` | One-shot agent context |
| `llms.txt` | `--llms` | `llms.txt` | Crawler / LLM discovery |
| RSS 2.0 | `--rss` | `rss.xml` | Recent-update feed |

Working context
: Default `--rag`. Bounded `working-N.md` packs of verbatim site documents
  plus a `manifest.json` sidecar that is **not** for upload. Never the
  `docs/rag/system` corpus.

Complete corpus
: `--rag --complete`. System + per-page + graph + catalog. Rejects
  `--scope`. Complete means the entire validated tree.

RSS
: Its own projection. Needs `--site-url`, `--rss-title`, and
  `--rss-description`. Eligible pages need `published_at` and `summary`.

<Aside kind="tip" id="working-not-system">

If you wanted the `docs/rag/system` teaching corpus, you wanted
`--rag --complete`. The default working pack is the *site*, on purpose.

</Aside>

## Commands {#commands}

```bash
./zig-out/bin/boris --out .boris --quiet
./zig-out/bin/boris --rag --quiet
./zig-out/bin/boris --rag --complete --quiet
./zig-out/bin/boris --context --quiet
./zig-out/bin/boris --llms --quiet
./zig-out/bin/boris --rss \
  --site-url https://docs.example/ \
  --rss-title "Example Docs" \
  --rss-description "Recent updates" \
  --quiet
```

Scoped working context still validates the full graph, then keeps the
subtree, its parents, and one-hop neighbors:

```bash
./zig-out/bin/boris --rag --scope guides --rag-dir ./uploads/rag
```

`--split-size` is a byte target (default `262144`), not a token estimate.
Whole documents are not split just to meet it.

## What an Aside becomes {#aside-export}

Source authoring stays PascalCase. RAG *export* uses `:::kind`. Do not type
`:::` in `content/`.

```markdown
<Aside kind="tip">

Use `boris validate` before publishing.

</Aside>
```

```text
:::tip
Use `boris validate` before publishing.
:::
```

<Details summary="IR, RAG, and llms.txt are not one artifact">

`--out` is IR. `--rag` is RAG. `--llms` is a discovery file. Putting them
under `dist/` in a script is an operational choice, not a compiler merge.
See [[reference/outputs|Outputs & Artifacts]] for the trees.

</Details>

## Next

- [[reference/outputs|Outputs & Artifacts]]
- [[reference/commands|Command Reference]]
- [[guides/publishing|Publishing Workflows]]
