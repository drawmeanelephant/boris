---
title: Outputs & Artifacts
parent: reference
status: published
tags: [reference, outputs, ir, rag, search]
---

<p class="eyebrow">Artifacts</p>

# Outputs & Artifacts {#outputs}

<Aside kind="info">

HTML `dist/` is the default target. IR, RAG, Context, `llms.txt`, and RSS
are separate invocations. Evidence under `_boris/proof/` is publication
of files, not a deployment claim.

</Aside>

Boris compiles one validated source tree into separate projections. A normal
HTML build is the default; machine exports are selected explicitly. Generated
directories are build products, not source-of-truth content.

## HTML site

```bash
./zig-out/bin/boris build --input content --html-dir dist
```

Typical output:

```text
dist/
  index.html
  getting-started.html
  guides/
    overview.html
    building-pages.html
  assets/
    css/boris.css
  _boris/
    search/
      search-index.json
    proof/
      artifacts.json
      checks.json
      claims.json
      touches.json
      proof-pack.json
      index.html
```

Page routes are `{entity-id}.html`; `guides/building-pages` becomes
`guides/building-pages.html`. Theme assets are copied under `assets/`, while
page-local assets follow the content-local asset contract. Navigation,
breadcrumbs, TOC, and other layout slots are embedded in each page.

`boris validate` exercises this HTML configuration without writing any of
these files.

## Compiler-owned rendered search

The normal HTML compiler writes the rendered search artifact at:

```text
dist/_boris/search/search-index.json
```

The default theme consumes it with a small browser UI and keeps a no-JavaScript
fallback link/list. A custom layout must provide a search root and its own
consumer if it wants interactive search; Boris does not inject a runtime into
arbitrary layouts.

The standalone search tool remains useful for a tree Boris did not build or for
explicit re-indexing experiments:

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

It uses the same producer and schema. It is not a required post-build step for
the normal Boris HTML path.

### Search schema 1

```json
{
  "format": "boris-rendered-search-index",
  "schema_version": 1,
  "documents": [
    {
      "path": "guides/building-pages.html",
      "title": "Building Pages",
      "sections": [
        {
          "level": 1,
          "heading": "Building Pages",
          "fragment": "building-pages",
          "text": "Pages are Markdown files under content/...",
          "code": ""
        }
      ]
    }
  ]
}
```

`path` is output-relative and ends in `.html`. Section `level` is `0` for
pre-heading text or `1`–`6` for a heading. `fragment` is the rendered heading
id; `text` and `code` keep prose and code searchable as separate fields.

## JSON IR

```bash
./zig-out/bin/boris build --out .boris
```

The chosen directory contains:

| File | Meaning |
|---|---|
| `manifest.json` | Compiler/version metadata and per-page records |
| `graph.json` | Frozen nodes and parent, reference, include, and semantic relation edges where present |
| `build-report.json` | Deterministic diagnostics, counts, and build information |

The current compiler identifier is `boris/0.8.1`; the relation-free IR schema
is `0.2.0`. Relation-bearing pages use IR schema `0.3.0`, as described in
[[reference/relationships|Relationships]]. Consumers should read the manifest's
schema field rather than infer it from a path.

## RAG corpus

```bash
./zig-out/bin/boris build --rag --rag-dir rag
```

The RAG tree contains:

```text
rag/
  INDEX.md
  UPLOAD-GUIDE.md
  catalog.jsonl
  catalog_meta.json
  system/
  content/pages/
  graph/
  parts/                    # only with --split-size
    part-1.md
    part_manifest.json
```

`catalog.jsonl` contains one record per published page. `content/pages/` holds
frontmatter-enriched Markdown, and `graph/` contains relationship summaries.
`--scope VALUE` selects a bounded branch after the complete graph is validated;
`--split-size BYTES` creates deterministic parts; `--bundles-only` omits the
per-page tree. `parent_entry` may appear in RAG catalog packaging, but it is an
export field—not an accepted source frontmatter key.

## Context bundle

```bash
./zig-out/bin/boris build --context --context-dir context
```

```text
context/
  bundle.md
  manifest.json
  graph.json
  pages/
  parts/                    # when --split-size is used
```

The bundle is an ordered Markdown context plus provenance and graph metadata.
Scoped bundles still validate the full source graph before projecting pages.

## `llms.txt`

```bash
./zig-out/bin/boris build --llms --llms-path public/llms.txt
```

The default path is `llms.txt`. Entries follow the validated navigation tree
and link to the current static routes, for example:

```text
- [Getting Started](/getting-started.html): Install and run Boris
```

## RSS and sitemap

RSS is an explicit projection:

```bash
./zig-out/bin/boris build --rss \
  --site-url https://docs.example/ \
  --rss-title "Example Docs" \
  --rss-description "Recent updates"
```

It writes `rss.xml` by default and requires `published_at` plus `summary` on
eligible items. A sitemap is attached to one HTML build:

```bash
./zig-out/bin/boris build --sitemap --site-url https://docs.example/
```

It writes `sitemap.xml` under the HTML target unless `--sitemap-path` changes
the target-relative path. `--site-url` must be an HTTP(S) deployment base.

## Publication evidence

HTML builds may include `_boris/proof/` reports for the local staged payload:
artifact inventory, checks, claims, touches, and a presentation proof pack.
They record bounded mechanical observations such as output paths, digests,
rendered fragments, search inventory, RSS, sitemap, and `llms.txt` checks. They
do not prove deployment reachability, accessibility, prose quality, or universal
reproducibility. Validation never emits them.

## What not to commit

Do not use `dist/`, `.boris/`, `rag/`, `context/`, search caches, or proof
reports as authored content. Keep generated output outside tracked source or in
ignored build directories.

## Related pages

- [[reference/commands|Command Reference]] — flags and modes
- [[guides/search-and-ui|Search & Browser UI]] — theme integration
- [[guides/rag-export|AI & Machine Outputs]] — export workflow
