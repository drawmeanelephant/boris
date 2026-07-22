# Boris

**The Content Exit Hatch**

Boris is a deterministic documentation compiler and static-site generator. It
turns Markdown into a validated static site, then can export the same content
graph as JSON IR, RAG, an AI Context Bundle, or `llms.txt`.

Write content locally. Build with one native binary. Get output you can inspect,
serve, archive, or hand to another tool.

[Migration guide](docs/MIGRATION.md) · [Architecture](docs/) · [Contracts](docs/contracts/) · [Status](docs/STATUS.md)

## What Boris does

```text
Markdown + frontmatter
          │
          ▼
 discover → validate graph → render
          │
          ├── HTML site          (--html-dir or dist/)
          ├── JSON IR            (--out)
          ├── RAG corpus         (--rag)
          ├── AI Context Bundle  (--context)
          └── llms.txt map       (--llms)
```

The content model is deliberately understandable: **Trunks** are primary
pages, **Satellites** belong to a Trunk, and in-page `Aside`/`Details` blocks
stay in document order. Broken parents, wiki-links, headings, includes, and
cycles fail with diagnostics instead of quietly producing a broken site.

## Features

- Native Markdown through the in-process ApexMarkdown C ABI.
- Deterministic HTML output with trusted static layouts and copied assets.
- Validated Trunk/Satellite navigation and graph-aware breadcrumbs/children.
- Closed, explicit frontmatter rather than unrestricted YAML or executable MDX.
- Incremental builds, watch mode, isolated targets, and bounded page workers.
- JSON IR with typed dependency edges and reverse indexes.
- Deterministic RAG, Context Bundle, and `llms.txt` exports from the same tree.
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

Building Boris requires [Zig 0.16+](https://ziglang.org/) and CMake. CMake is
used to build the vendored native Markdown engine; it is not part of the
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
./zig-out/bin/boris --out .boris --quiet       # JSON IR
./zig-out/bin/boris --rag --quiet              # RAG corpus
./zig-out/bin/boris --context --quiet          # AI Context Bundle
./zig-out/bin/boris --llms --quiet             # llms.txt
./zig-out/bin/boris check                      # graph-health report
./zig-out/bin/boris impact getting-started    # dependency impact report
zig build test
```

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

## Outputs from one content tree

| Command | Output | Best for |
| --- | --- | --- |
| `boris` | HTML under `dist/` | Publishing a static site |
| `boris --out .boris` | JSON IR | Build tools and inspection |
| `boris --rag` | RAG corpus | LLM retrieval and audits |
| `boris --context` | Context Bundle | Provenance-rich agent context |
| `boris --llms` | `llms.txt` | Lightweight machine discovery |

These are separate output modes from the same source tree. They do not silently
merge into one opaque build product.

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

The `--context`, `--rag`, and `--llms` modes are practical parts of the product,
not hosted AI services. They emit local, deterministic artifacts that can be
reviewed or uploaded to an LLM when useful.

## Roadmap

- [x] Deterministic HTML, JSON IR, graph validation, and native Apex Markdown.
- [x] Incremental/watch builds, bounded jobs, multi-target output, and assets.
- [x] RAG, Context Bundle, and `llms.txt` exports.
- [x] Migration labs and real-site dogfood evidence.
- [x] v0.7.0 release and migration-lab theme/link evidence.
- [x] v0.8.0 release packaging, ApexMarkdown 1.1.13, and source-RAG upload ergonomics.
- [ ] Relationship inventory and archive-layout dogfood.
- [ ] Real-theme materialization and controlled migration benchmarks.
- [ ] Broader migration fixtures for Astro/Starlight and WordPress.
- [ ] Explicit metadata/provenance namespace for custom source fields.

## Honest limitations

- Zig 0.16+ and CMake are required to build Boris itself.
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
- [`examples/`](examples/) — themes and dogfood fixtures
- [`CHANGELOG.md`](CHANGELOG.md) — release history

## License

Boris is released under the [MIT License](LICENSE).
