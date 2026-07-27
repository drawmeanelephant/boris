---
title: Boris Documentation
status: published
tags: [home, zig, documentation]
---

# Boris — a compiler for documentation that stays honest

Boris is a zero-dependency static documentation compiler. You write rich Markdown files with explicit page relationships (`parent` and wiki-links), and Boris validates your documentation graph before emitting static HTML, a client-side search index, JSON IR, RAG packages, AI Context Bundles, and `llms.txt`—all from a single fast, native binary with no JavaScript runtime or Node.js toolchain required.

<Aside kind="info">

**Layer 1 Summary:** Boris is not a JS site stack or hosted CMS. It is a local native binary that turns Markdown files into a validated graph and produces static outputs for both human readers and AI agents.

</Aside>

## 5-Minute Quickstart (Layer 2)

Get your complete documentation site—including HTML, full-text search, and AI machine exports—up and running in 4 commands:

```bash
# 1. Compile the site with the corporate layout
./zig-out/bin/boris --theme examples/prototype-corporate --html-dir dist

# 2. Build the client-side search index
zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search

# 3. Generate machine exports for AI agents (RAG corpus, IR, Context Bundle, llms.txt)
./zig-out/bin/boris --rag --rag-dir dist/rag --quiet
./zig-out/bin/boris --out dist/.boris --quiet
./zig-out/bin/boris --llms --llms-path dist/llms.txt --quiet
./zig-out/bin/boris --context --context-dir dist/context --quiet

# 4. Open dist/index.html in your browser
```

**Visible Outcome:** A complete, beautifully styled documentation site under `dist/` with graph-backed sidebar navigation, breadcrumbs, table-of-contents, instant client-side search, and AI-ready markdown/JSON packages.

## Documentation Navigation Map (Layer 3)

Explore how Boris works under the hood and how to leverage its capabilities:

| Goal | Destination | What you will learn |
|---|---|---|
| **Get Started** | [[getting-started|Getting Started]] | Step-by-step setup, first useful action, and common developer/agent hesitations |
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
