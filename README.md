# Boris

**The Content Exit Hatch**

Boris is a deterministic documentation compiler and static-site generator. It
turns Markdown into a validated static site, then can export the same content
graph as JSON IR, RAG, an AI Context Bundle, `llms.txt`, or RSS 2.0. HTML
builds can also publish a deterministic XML sitemap.

Write content locally. Build with one native binary. Get output you can inspect,
serve, archive, or hand to another tool.

[Migration guide](docs/MIGRATION.md) · [Architecture](docs/) · [Contracts](docs/contracts/) · [Status](docs/STATUS.md) · [GitHub Pages](docs/github-pages.md)

## What Boris does

```text
Markdown + frontmatter
          │
          ▼
 discover → validate graph → render
          │
          ├── HTML site          (--html-dir or dist/, optional --sitemap)
          ├── JSON IR            (--out)
          ├── RAG corpus         (--rag)
          ├── AI Context Bundle  (--context)
          ├── llms.txt map       (--llms)
          └── RSS 2.0 feed       (--rss)
```

The content model is deliberately understandable: **Trunks** are root pages,
**Satellites** are explicitly parented non-root pages (including nested parent
chains), and in-page `Aside`/`Details` blocks stay in document order. Broken
parents, wiki-links, headings, includes, and cycles fail with diagnostics
instead of quietly producing a broken site.

## Features

- Native Markdown through the pinned **Oliver** library (Zig, in-process).
- Deterministic HTML output with trusted static layouts and copied assets.
- Validated Trunk/Satellite navigation and graph-aware breadcrumbs/children.
- Closed, explicit frontmatter rather than unrestricted YAML or executable MDX.
- Authoritative `boris validate` preflight with no generated output or evidence.
- Incremental builds, watch mode, isolated targets, and bounded page workers.
- JSON IR with typed dependency edges and reverse indexes.
- Deterministic RAG, Context Bundle, `llms.txt`, and RSS 2.0 exports from the same tree.
- Deterministic staged XML sitemap for one public HTML target.
- First-class GitHub Pages publication identity and an official verified Actions workflow.
- Standalone migration labs for Astro/Starlight, WordPress, Instagram, Obsidian,
  Notion, and related source shapes.

## Why Boris?

Most documentation stacks are also JavaScript application toolchains. Boris
takes a narrower path: a local Zig binary that treats documentation as a
validated content graph rather than a folder full of unrelated pages. That
means fewer moving parts in the publishing path, explicit failure when the
structure is wrong, and several machine-readable outputs without maintaining a
second content model.

Boris is not trying to replace every SSG. It is for people who want a small,
inspectable compiler, graph-aware documentation, and a useful hand-off to AI
tools without requiring a Node runtime to publish the site.

## Quick start

Building Boris requires [Zig 0.16+](https://ziglang.org/) only. Markdown
rendering is Oliver, a pure-Zig library pinned by content hash in
`build.zig.zon` and fetched by Zig at build time; it is not part of the
authoring or publishing workflow.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
./zig-out/bin/boris --quiet
```

The sample content is compiled to `dist/`. Open `dist/index.html` or serve the
directory with any static file server.

Useful first commands:

```bash
./zig-out/bin/boris --help
./zig-out/bin/boris --version                 # print the compiler id (e.g. boris/0.8.1)
./zig-out/bin/boris --out .boris --quiet       # JSON IR
./zig-out/bin/boris --rag --quiet              # RAG working-context packs
./zig-out/bin/boris --rag --complete --quiet    # complete-corpus RAG export
./zig-out/bin/boris --context --quiet          # AI Context Bundle
./zig-out/bin/boris --rag-dir ./uploads/rag --scope mascots --split-size 262144
./zig-out/bin/boris --context-dir ./uploads/context --scope mascots/genny --split-size 131072
./zig-out/bin/boris --llms --quiet             # llms.txt
./zig-out/bin/boris --rss --site-url https://docs.example/ --rss-title "Example Docs" --rss-description "Recent updates" --quiet
./zig-out/bin/boris --sitemap --site-url https://docs.example/ --quiet
./zig-out/bin/boris validate --quiet             # HTML source/config preflight; no output
./zig-out/bin/boris check                      # graph-health report
./zig-out/bin/boris impact getting-started    # dependency impact report
zig build test
```

The repository’s GitHub Pages publication path is documented in
[`docs/github-pages.md`](docs/github-pages.md). It uses the native Boris
compiler, keeps proof reports in a retained evidence artifact, and uploads
only the exact public files declared by the target inventory.

### Add a page

Create a Markdown file under `content/`:

```markdown
---
title: My first satellite
parent: getting-started
status: published
tags: [guides]
---

# My first satellite

Ship docs with one binary.
```

The author-facing parent key is `parent`. Legacy names such as `parentEntry`
and `parent_entry` are intentionally rejected; see the
[frontmatter contract](docs/contracts/frontmatter.md).

### Working-context RAG packs

The default `--rag` export is a **working context**: a small number of bounded
upload files containing the selected site documents (frontmatter, H1s,
`<Aside>` / `<Details>` authoring syntax preserved) and the required site graph
closure — never the `docs/rag/system` corpus — plus a `manifest.json` sidecar
that is **not meant to be uploaded**. Attachment count and context size are
first-class constraints; integrity records live in the sidecar, not in the
model-facing files.

```bash
# Working context for the whole site (bounded packs + sidecar)
./zig-out/bin/boris --rag --rag-dir ./uploads/rag

# Scoped working context: the subtree, its parents, and one-hop neighbors
./zig-out/bin/boris --rag-dir ./uploads/rag/mascots --scope mascots

# Explicit complete-corpus export (system + per-page + graph + catalog)
./zig-out/bin/boris --rag --complete --rag-dir ./uploads/rag-complete

# Single-record Context Bundle with complete pages plus upload parts
./zig-out/bin/boris --context-dir ./uploads/context/genny \
  --scope mascots/028.genny-compileheart --split-size 131072
```

After a working export Boris prints what you actually need to know: selected
pages, structural parents and semantic neighbors pulled in, the exact upload
file paths, approximate bytes and tokens, and the `manifest.json` sidecar
identified separately as a non-upload file. `--complete` is the explicit
full-corpus export (system + per-page + graph + catalog) and rejects `--scope`:
complete means the entire validated corpus.

`--split-size` is the working-pack target in bytes (default 262144), not a
model token estimate — and whole documents are never split merely to meet it;
only a single document larger than the target is split, at safe Markdown
paragraph or heading boundaries outside fenced code. An indivisible block
larger than the target fails without replacing an existing export. See the
[RAG export contract](docs/contracts/rag-export.md).

## Outputs from one content tree

| Command | Output | Best for |
| --- | --- | --- |
| `boris` | HTML under `dist/` | Publishing a static site |
| `boris validate` | None | Compiler-authoritative HTML source/configuration preflight |
| `boris --sitemap --site-url URL` | HTML plus `sitemap.xml` | Crawler URL discovery |
| `boris --out .boris` | JSON IR | Build tools and inspection |
| `boris --rag` | Working-context packs | LLM site authoring (bounded uploads) |
| `boris --rag --complete` | Complete RAG corpus | Full-tree LLM retrieval and audits |
| `boris --context` | Context Bundle | Provenance-rich agent context |
| `boris --llms` | `llms.txt` | Lightweight machine discovery |
| `boris --rss` | RSS 2.0 XML | Recent documentation updates |

The machine exports are separate output modes from the same source tree; they
do not silently merge into one opaque build product. Sitemap is the exception
shown explicitly above: it is an HTML-build flag, not a separate content projection.
`--sitemap-path PATH` changes its target-relative path and implies
`--sitemap`. A sitemap is a discovery hint, not a guarantee that a search
engine will crawl or index a page.

`boris validate` follows the normal HTML compiler through its bounded
prepublication render phases, then stops before creating a target or stage.
It is distinct from `check`, which adds graph-health policy, and from normal
build publication/evidence. See the
[validation contract](docs/contracts/validation.md) for the exact boundary.

The canonical [publication model](docs/contracts/publication-model.md) defines
which values are document facts, publication facts, migration provenance, or
projection evidence. Selecting or emitting one output does not merge its
contract with another output or prove deployment correctness.

RSS is opt-in and does not modify themes. After publishing `rss.xml`, add this
standard discovery hint to a layout when the deployed feed URL is known:

```html
<link rel="alternate" type="application/rss+xml" title="Feed title" href="/rss.xml">
```

## Benchmarking

Boris performance should be measured on a stated machine, toolchain, content
tree, optimization mode, and worker count. A single fast run is not a
benchmark.

The reproducible benchmark work lives under [`benchmark/`](benchmark/) and
records raw command output, repeated-run statistics, output sizes, file counts,
determinism, and known equivalence limits. The headline comparison uses the
median, not the fastest run.

The benchmark compares a controlled Astro 6.x/7.x pair against the Boris Filed
dogfood build. It also preserves a historical Astro snapshot separately so
source/config drift is not hidden behind a headline number.

## Migration

Migration is a workflow, not a promise of one-click conversion:

```text
inspect → select a bounded slice → preserve/propose/review
       → compile HTML + IR → inspect the result → expand carefully
```

The migration labs are standalone developer aids. They can inventory source
trees, identify relationships and unsupported constructs, materialize reviewed
themes, and produce manual-review reports. They do not add Astro, Node, or an
MDX runtime to Boris core.

Start with [`docs/MIGRATION.md`](docs/MIGRATION.md), then review the dogfood
examples under [`docs/dogfood/`](docs/dogfood/).

## AI and OpenAI Build Week

Boris was built through continuous human–AI collaboration using ChatGPT 5.6,
Codex, delegated implementation, hostile testing, migration audits, and
deliberate scope cuts. AI accelerated exploration and execution; the project’s
contracts, boundaries, acceptance decisions, and final merges remained
human-steered.

The `--context`, `--rag`, `--llms`, and `--rss` modes are practical parts of the product,
not hosted AI services. They emit local, deterministic artifacts that can be
reviewed or uploaded to an LLM when useful.

## Roadmap

- [x] Deterministic HTML, JSON IR, graph validation, and native Oliver Markdown.
- [x] Incremental/watch builds, bounded jobs, multi-target output, and assets.
- [x] RAG, Context Bundle, `llms.txt`, and RSS 2.0 exports.
- [x] Migration labs and real-site dogfood evidence.
- [x] v0.7.0 release and migration-lab theme/link evidence.
- [x] v0.8.1 candidate packaging and source-RAG upload ergonomics.
- [ ] Relationship inventory and archive-layout dogfood.
- [ ] Real-theme materialization and controlled migration benchmarks.
- [ ] Broader migration fixtures for Astro/Starlight and WordPress.
- [ ] Explicit metadata/provenance namespace for custom source fields.

## Honest limitations

- Zig 0.16+ is required to build Boris itself.
- Frontmatter is intentionally closed; Boris is not a general YAML parser.
- Unrestricted MDX and executable JavaScript components are out of scope.
- Raw HTML is trusted input and is not sanitized by default.
- Ordinary Markdown links are not a complete site-wide link checker.
- Migration labs are bounded aids, not universal importers.
- Cross-platform byte identity and speed claims require measured evidence.

## Project map

- [`docs/STATUS.md`](docs/STATUS.md) — current phase and known gaps
- [`docs/contracts/`](docs/contracts/) — normative behavior
- [`docs/MIGRATION.md`](docs/MIGRATION.md) — migration workflow
- [`docs/RELEASE-GATE.md`](docs/RELEASE-GATE.md) — release checks
- [`tools/migration-lab/`](tools/migration-lab/) — standalone migration tools
- [`tools/source-rag/`](tools/source-rag/) — source-code RAG exporter
- [`tools/content-audit/`](tools/content-audit/) — standalone deterministic source-content audit tool
- [`examples/`](examples/) — themes and dogfood fixtures
- [`CHANGELOG.md`](CHANGELOG.md) — release history

## License

Boris is released under the [MIT License](LICENSE).
