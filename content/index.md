---
title: Boris Documentation
status: published
tags: [home, zig, documentation]
---

# Boris — a static documentation compiler that stays honest

Boris is a zero-dependency static documentation compiler. You write rich Markdown files with explicit page relationships (`parent` and wiki-links), and Boris validates your documentation graph before emitting static HTML, a client-side search index, JSON IR, RAG packages, AI Context Bundles, and `llms.txt`—all from a single fast, native binary with no JavaScript runtime or Node.js toolchain required.

<Aside kind="info">

**Layer 1 Summary:** Boris is not a JS site stack or hosted CMS. It is a local native binary that turns Markdown files into a validated graph and produces static outputs for both human readers and AI agents.

</Aside>

## At a Glance: Boris vs. Alternatives

| Approach | Build Toolchain | Link & Graph Safety | Machine Outputs | Client JS Footprint |
| :--- | :--- | :--- | :--- | :--- |
| **Plain Markdown** | None | Broken links in prod | Manual scraping | None |
| **JS Frameworks (Docusaurus, Astro)** | Node.js, npm, Webpack/Vite | Best-effort / optional plugins | Custom scripts required | Large JS bundles (React/Hydration) |
| **Boris Documentation Compiler** | **Single native Zig binary** | **Strict Fail-Loud Validation** | **Native RAG, IR, Context, `llms.txt`** | **Zero required JS** |

## Essential Concepts

Trunk Node
: A root page without a `parent` key. Serves as the top-level anchor of a navigation section.

Satellite Node
: A page declaring `parent: <entity-id>` in its frontmatter. Nests under its parent in navigation.

Entity ID
: Page identifier derived from path (e.g. `guides/overview.md` becomes `guides/overview`).

Callout Aside
: Registered in-document component (`&lt;Aside kind="note|tip|info|warning|danger"&gt;`) for structured callouts.

Machine Exports
: Native target formats (`--rag`, `--out`, `--context`, `--llms`) emitted from the exact same validated graph.

## 5-Minute Quickstart

Get your static documentation site up and running in two commands:

```bash
zig build
./zig-out/bin/boris
```

Open `dist/index.html` in your browser to view your site with graph-backed sidebar navigation, breadcrumbs, and in-page table of contents.

### Optional Build Branches

- **Add Client-Side Search Index**:
  ```bash
  zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search
  ```
- **Export Machine AI Artifacts** (`dist/rag/`, `dist/.boris/`, `dist/context/`, `dist/llms.txt`):
  ```bash
  ./zig-out/bin/boris --rag --rag-dir dist/rag --quiet
  ./zig-out/bin/boris --out dist/.boris --quiet
  ./zig-out/bin/boris --llms --llms-path dist/llms.txt --quiet
  ./zig-out/bin/boris --context --context-dir dist/context --quiet
  ```

## Source-to-Output Specimen

Here is how a single Markdown source page transforms into human site HTML and machine outputs:

### 1. Markdown Source (`content/getting-started.md`)
```markdown
---
title: Getting Started
parent: index
status: published
---
# Getting Started with Boris

See [[guides/overview|Content Model]] for pipeline details.
```

### 2. Validated Graph Structure (Roll Phase)
```text
Node: getting-started (Satellite of index)
Links: [[guides/overview]] → VALIDATED
```

### 3. Human HTML Output (`dist/getting-started.html`)
```html
<nav class="sidebar"><ul><li><a href="/getting-started.html" class="active">Getting Started</a></li></ul></nav>
<main><h1>Getting Started with Boris</h1><p>See <a href="/guides/overview.html">Content Model</a> for pipeline details.</p></main>
```

### 4. Machine Export Record (`dist/rag/catalog.jsonl`)
```json
{"entity_id":"getting-started","title":"Getting Started","parent":"index","status":"published"}
```

## Documentation Navigation Map

Explore how Boris works under the hood and how to leverage its capabilities:

| Goal | Destination | What you will learn |
|---|---|---|
| **Get Started** | [[getting-started|Getting Started]] | Step-by-step setup, first useful action, and common hesitations |
| **Why Boris?** | [[comparison|Comparison & Rationale]] | Contrast Boris with Docusaurus, Astro, MDX, CMSs, and plain Markdown |
| **Understand Mental Model** | [[guides/overview|Content Model & Pipeline]] | Trunk/Satellite graphs, fail-loud validation, and the 4-stage pipeline |
| **Explore CLI & Modes** | [[guides/cli-and-modes|CLI & Output Modes]] | HTML, IR, RAG, Context, `llms.txt`, watch mode, check mode, and `--jobs` |
| **Search & Layouts** | [[guides/search-and-ui|Search & Themes]] | Standalone search index tool, HTML marker tokens, zero-JS fallbacks |
| **AI Agent Export** | [[guides/rag-export|RAG & AI Outputs]] | How LLMs and agents consume Boris documentation |
| **Markdown & Components** | [[guides/apex-markdown|ApexMarkdown]] | In-process Markdown features, callout Aside components, wiki-links, and includes |
| **Troubleshooting** | [[reference/diagnostics|Diagnostics & Error Codes]] | Diagnostic codes (`EFRONTMATTER`, `EGRAPH`, `EINC`), closed grammar rules, and fixes |

## One source, several outputs

Boris compiles the same frozen, validated content graph into all required formats without duplication:

```bash
./zig-out/bin/boris                          # HTML site → dist/
./zig-out/bin/boris --out .boris             # JSON IR → .boris/
./zig-out/bin/boris --rag                    # RAG corpus → rag/
./zig-out/bin/boris --context                # AI Context Bundle → context/
./zig-out/bin/boris --llms                   # llms.txt → llms.txt
```

Validation runs *before* any file is written. If a parent link or wiki-link is broken, Boris fails loudly with exit code `1`—preventing partial or corrupt publications.
