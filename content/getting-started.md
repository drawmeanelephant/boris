---
title: Getting Started
status: published
tags: [setup, quickstart, cli]
summary: Build Boris, preflight the sample, publish dist/, then choose a hosted target if you want one.
---

<p class="eyebrow">Onboarding</p>

# Getting Started with Boris {#getting-started}

{{include includes/identity.md}}

The shortest useful path is: build Boris, preflight the sample content, build
the site, open the HTML. Hosted targets come after that.

<Aside kind="info" id="search-comes-along">

The default HTML build also publishes a rendered-search artifact and
target-local publication evidence. You do not need to run a second search
index command for a normal Boris build.

</Aside>

{{include includes/shared-tip.md}}

## 1. Build Boris {#build-boris}

Building Boris itself requires:

- **Zig 0.16+** — the compiler language Boris is written in. Markdown
  rendering uses the Oliver library, pinned in `build.zig.zon` and fetched by
  Zig at build time — no CMake or other host tools are required.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
```

The binary is written to `./zig-out/bin/boris`.

## 2. Inspect the sample content {#inspect}

Pages are ordinary Markdown files under `content/`. The path without its
extension is normally the page's entity id: `content/guides/overview.md`
becomes `guides/overview`. Start with
[[guides/building-pages|Building Pages]] if you want to add a page, or
[[guides/oliver-markdown|the Markdown showcase]] if you want to see what
Oliver will actually render.

## 3. Preflight without publishing {#preflight}

```bash
./zig-out/bin/boris validate --quiet
```

`validate` runs Boris's authoritative HTML source and configuration checks,
including graph resolution, component parsing, layout loading, and bounded
render preparation. It creates no HTML, cache, search, or publication-evidence
files.

<Aside kind="tip" id="validate-vs-check">

`validate` is not `check`. `check` is graph-health policy after the graph is
already valid. Use `validate` to ask “would this compile?” Use `check` to
ask “is this graph healthy?”

</Aside>

## 4. Publish the static site {#publish-local}

```bash
./zig-out/bin/boris build --quiet
```

The default target is `dist/`. Open `dist/index.html` directly for reading, or
serve the `dist/` directory with any static file server when you want the
browser search UI to fetch its same-origin index.

{{include includes/publish-first.md}}

## 5. Then choose a hosted target {#hosted}

Local `dist/` is the default. It is not the only exit.

| Next | When | Guide |
| :--- | :--- | :--- |
| Stay local | You wanted files | You are done |
| GitHub Pages | First verified hosted target | [[guides/publishing#github-pages|Publishing → Pages]] |
| Standard.site | Atmosphere records | [[guides/publishing#standard-site|Publishing → Standard.site]] |
| Editor | You want a local authoring UI | [[guides/editor|Boris Editor]] |

<Details summary="What you should not do on day one">

Do not start with browser OAuth against bsky.social. Do not type an app
password on argv. Do not edit files under `dist/`. Do not run the standalone
search-index tool after a normal Boris build. Do not start day one with
`boris nostr publish` — that family exists; it is not the first command.

</Details>

## What to learn next {#next}

- [[guides/overview|Content Model & Pipeline]] — how discovery, graph
  validation, rendering, and projections fit together.
- [[guides/publishing|Publishing Targets]] — Pages, Standard.site, and the
  evidence chain.
- [[guides/cli-and-modes|CLI & Output Modes]] — build, validate, watch, graph
  analysis, layouts, and machine exports.
- [[guides/oliver-markdown|Markdown Showcase]] — tables, footnotes, definition
  lists, heading ids, and everything this site is allowed to flex.
- [[reference/frontmatter|Frontmatter Reference]] — the complete closed author
  grammar.
- [[reference/outputs|Outputs & Artifacts]] — HTML, search, IR, RAG, Context,
  `llms.txt`, RSS, sitemap, and publication evidence.
