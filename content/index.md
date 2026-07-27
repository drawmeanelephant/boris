---
title: Boris Documentation
status: published
tags: [home, zig, documentation]
---

# Write expressive Markdown. Ship a complete documentation site.

Boris compiles your Markdown graph into a polished static site for human readers alongside aligned editions for search tools, AI agents, and crawler indexes when generated from the same source revision.

[[getting-started|Get Started in 5 Minutes]] · [Explore Documentation Map](#documentation-navigation-map)

<div class="specimen-grid">
  <div class="specimen-card">
    <div class="specimen-card__header">Live Rendered Site Output</div>
    <div class="specimen-card__body">
      <p class="eyebrow">Rendered Frame Preview</p>
      <p><strong>Graph-backed layout:</strong> Sticky navigation sidebar, breadcrumb hierarchy, in-page TOC anchors, and styled callout asides.</p>
    </div>
  </div>
  <div class="specimen-card">
    <div class="specimen-card__header">Rendered Site Evidence</div>
    <div class="specimen-card__body">
      <p>Screenshots captured from a local HTTP server and published as content-local assets:</p>
      <ul>
        <li><a href="index.assets/desktop.png">Desktop Viewport (1280×800)</a></li>
        <li><a href="index.assets/mobile.png">Mobile Viewport (375×812)</a></li>
        <li><a href="index.assets/search_open.png">Search Results Open</a></li>
      </ul>
    </div>
  </div>
</div>

---

## Authoring Specimen & Rendered Output

*Condensed specimen adapted from `content/guides/overview.md`:*

<div class="specimen-grid">
  <div class="specimen-card">
    <div class="specimen-card__header">1. Markdown Source (content/guides/overview.md)</div>
    <div class="specimen-card__body">

```markdown
---
title: Site Structure & Page Graph
parent: guides
status: published
---

Think of Boris as a compiler for your site's structure.

<Aside kind="tip">

Every parent relationship must resolve before HTML is written.

</Aside>
<aside class="admonition admonition--info" aria-label="Info" style="margin: 0.75rem 0;">
  <p><strong>Graph Validation:</strong> Parent chains and wiki-links are verified before writing files to disk.</p>
</aside>

<table style="font-size: 0.82rem; margin-top: 0.5rem;">
  <thead><tr><th>Phase</th><th>Action</th></tr></thead>
  <tbody>
    <tr><td><strong>Load</strong></td><td>Discover Markdown files</td></tr>
    <tr><td><strong>Roll</strong></td><td>Parse frontmatter &amp; validate graph</td></tr>
  </tbody>
</table>

    </div>
  </div>
</div>

---

## One Source, Aligned Editions

Boris’s human and machine editions originate from the same validated documentation source and relationships when generated from the same source revision. The standalone search tool then indexes the resulting HTML.

*Real output excerpts generated from current source revision:*

<div class="edition-grid">
  <div class="edition-card">
    <span class="edition-card__tag">Human Site</span>
    <h3>Static HTML Site</h3>
    <p>Default compilation mode writing styled HTML pages with sticky sidebars, breadcrumbs, and TOCs.</p>
    <code>./zig-out/bin/boris</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code>&lt;nav class="breadcrumb"&gt;
  &lt;ol&gt;&lt;li&gt;Boris Documentation&lt;/li&gt;&lt;/ol&gt;
&lt;/nav&gt;</code></pre>
  </div>

  <div class="edition-card">
    <span class="edition-card__tag">Browser Search</span>
    <h3>Rendered-Site Search Index</h3>
    <p>Standalone search tool parsing section fragments and headings directly from rendered HTML.</p>
    <code>zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code>{"format":"boris-rendered-search-index",
 "documents":[{"path":"getting-started.html"}]}</code></pre>
  </div>

  <div class="edition-card">
    <span class="edition-card__tag">Programmatic</span>
    <h3>JSON IR 0.2.0</h3>
    <p>Structured intermediate representation capturing frozen graph topology and frontmatter metadata.</p>
    <code>./zig-out/bin/boris --out .boris</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code>{"schemaVersion":"0.2.0",
 "compiler":"boris/0.8.1",
 "pageCount":22}</code></pre>
  </div>

  <div class="edition-card">
    <span class="edition-card__tag">AI & LLM</span>
    <h3>RAG Corpus & Catalog</h3>
    <p>Markdown chunk corpus and JSONL catalog formatted for direct vector database ingestion.</p>
    <code>./zig-out/bin/boris --rag</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code>{"rag_id":"content/getting-started",
 "rag_path":"content/pages/getting-started.md"}</code></pre>
  </div>

  <div class="edition-card">
    <span class="edition-card__tag">Context Bundle</span>
    <h3>AI Context Bundle Directory</h3>
    <p>Directory containing aggregated <code>bundle.md</code>, graph, manifest, and page artifacts. Default destination is <code>context/</code>; use <code>--context-dir</code> to place it under <code>dist/</code>.</p>
    <code>./zig-out/bin/boris --context --context-dir dist/context</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code>dist/context/
├── bundle.md (aggregated text)
├── graph.json &amp; manifest.json
└── pages/ (page artifacts)</code></pre>
  </div>

  <div class="edition-card">
    <span class="edition-card__tag">Machine Index</span>
    <h3>LLM Documentation Index</h3>
    <p>Standardized <code>llms.txt</code> index mapping documentation routes for AI assistants and web crawlers.</p>
    <code>./zig-out/bin/boris --llms</code>
    <pre style="margin-top:0.5rem;font-size:0.75rem;"><code># Boris documentation
> Generated from validated Trunk/Satellite graph.
- [Getting Started](/getting-started/)</code></pre>
  </div>
</div>

---

## Verified Site-Building Capabilities

Boris directly provides the documentation-site capabilities shown below:

<div class="feature-grid">
  <div class="feature-card">
    <h3>Themes & Layout Templates</h3>
    <p>Modular HTML layout templates (<code>themes/boris/layouts/main.html</code>) with explicit slot tokens (<code>{{nav}}</code>, <code>{{breadcrumb}}</code>, <code>{{toc}}</code>, <code>{{content}}</code>).</p>
  </div>
  <div class="feature-card">
    <h3>Graph-Backed Navigation Tree</h3>
    <p>Automatic multi-level sidebar navigation tree generated directly from <code>parent</code> frontmatter declarations.</p>
  </div>
  <div class="feature-card">
    <h3>Breadcrumb Trail & TOC</h3>
    <p>Breadcrumb navigation chains and in-page table of contents anchors automatically derived from heading levels (<code>h1</code>–<code>h3</code>).</p>
  </div>
  <div class="feature-card">
    <h3>Page-Local Static Assets</h3>
    <p>Theme CSS assets (<code>themes/boris/assets/css/boris.css</code>) copied directly to output directories without external asset pipelines.</p>
  </div>
  <div class="feature-card">
    <h3>Incremental & Parallel Builds</h3>
    <p><code>--incremental</code> mode skips unchanged pages; <code>--jobs N</code> distributes HTML rendering across worker threads.</p>
  </div>
  <div class="feature-card">
    <h3>Watch Mode & Check Mode</h3>
    <p><code>--watch</code> continuously re-compiles on file edits; <code>check</code> validates content graph relationships without writing files.</p>
  </div>
</div>

---

## Build-Time Graph Safety & Product Scope

Boris validates parent relationships and supported internal wiki-links during the Roll phase before any output file is written to disk. If a parent reference or wiki-link fails to resolve, Boris halts with exit code 1:

```text
error: EREFERENCEMISSING: content/index.md:12:1: unresolved wiki-link target "guides/non-existent"
Build status: FAILED (Exit code 1) — No output written to dist/
```

### Focused Product Boundaries

- **Zero Node/npm Toolchain:** Single native executable written in Zig. No `package.json`, no `node_modules` dependency tree to audit or update, and no JavaScript build steps for core site compilation.
- **Zero Required Client JS:** Navigation, breadcrumbs, TOC, page reading, and responsive layouts function entirely with standard HTML/CSS and zero JavaScript.
- **Closed Frontmatter Grammar:** Enforces a strict 5-key frontmatter contract (<code>id</code>, <code>title</code>, <code>parent</code>, <code>status</code>, <code>tags</code>). Unknown keys emit clear <code>EFRONTMATTER</code> diagnostic errors.

---

## 2-Command Quickstart

Get your static documentation site up and running in two commands:

```bash
zig build
./zig-out/bin/boris
```

Open <code>dist/index.html</code> in your browser to view your site.

### Optional Build Invocations

- **Generate Client-Side Search Index**:
  ```bash
  zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search
  ```
- **Export Aligned Machine Editions**:
  ```bash
  ./zig-out/bin/boris --out .boris --quiet
  ./zig-out/bin/boris --rag --quiet
  ./zig-out/bin/boris --context --quiet
  ./zig-out/bin/boris --llms --quiet
  ```

---

<h2 id="documentation-navigation-map">Documentation Navigation Map</h2>

| Goal | Destination | What you will learn |
| :--- | :--- | :--- |
| **Get Started** | [[getting-started|Getting Started]] | Step-by-step setup, first useful action, and common hesitations |
| **Why Boris?** | [[comparison|Comparison & Rationale]] | Contrast Boris with JS site generators and plain Markdown |
| **Understand Mental Model** | [[guides/overview|Content Model & Pipeline]] | Trunk/Satellite page graphs, fail-loud validation, and the 4-stage pipeline |
| **Explore CLI & Modes** | [[guides/cli-and-modes|CLI & Output Modes]] | HTML, IR, RAG, Context, <code>llms.txt</code>, watch mode, check mode, and <code>--jobs</code> |
| **Search & Layouts** | [[guides/search-and-ui|Search & Themes]] | Standalone search index tool, HTML marker tokens, zero-JS fallbacks |
| **AI Agent Export** | [[guides/rag-export|RAG & AI Outputs]] | How LLMs and agents consume Boris documentation |
| **Markdown & Components** | [[guides/apex-markdown|ApexMarkdown]] | In-process Markdown features, callout Aside components, wiki-links, and includes |
| **Troubleshooting** | [[reference/diagnostics|Diagnostics & Error Codes]] | Diagnostic codes (<code>EFRONTMATTER</code>, <code>EPARENTMISSING</code>, <code>EREFERENCEMISSING</code>), closed grammar rules, and fixes |
