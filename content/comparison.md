---
title: Why Boris? (Comparison & Rationale)
parent: index
status: published
tags: [rationale, comparison, architecture]
---

# Why Boris? (Comparison & Rationale)

Boris is a dedicated static documentation compiler. This document contrasts Boris with traditional static site generators, JavaScript web frameworks, hosted CMS platforms, and plain Markdown files.

<Aside kind="info">

**Core Difference:** Boris treats documentation as a validated, directed graph and compiles it into static HTML, client-side search, and machine AI exports from a single native binary—without Node.js, npm dependencies, or JavaScript runtime build steps.

</Aside>

---

## Boris vs. Other Approaches

| Feature / Goal | Plain Markdown / Wiki | JS Frameworks (Docusaurus, Next.js, Astro) | Boris Documentation Compiler |
|---|---|---|---|
| **Build Runtime** | None (Raw files) | Node.js, npm, Webpack/Vite, React/Vue | Single native Zig binary (Zero runtime dependencies) |
| **Build Speed** | N/A | Seconds to minutes (JS bundling overhead) | Sub-second native execution |
| **Page Link & Graph Validation** | None (Broken links in prod) | Optional plugins (often slow/partial) | **Strict Fail-Loud Graph Validation** before writing output |
| **Rich Markdown** | Basic CommonMark | MDX (arbitrary executable JS) | **Rich ApexMarkdown**: Callout Asides, footnotes, wiki-links, transclusion |
| **Full-Text Search** | External service (Algolia) | Bundled JS indexers or external search | **Built-in Standalone Search Indexer** |
| **Machine & AI Exports** | Manual scraping or plugins | Custom build scripts | **Native Exports**: JSON IR 0.2.0, RAG corpus, AI Context Bundle, `llms.txt` |
| **Client JS Footprint** | None | Large React/Hydration JS bundles | **Zero Required Client JS** (Optional lightweight search script) |

---

## 1. Boris vs. JavaScript Site Generators (Docusaurus, Astro, Starlight)

JavaScript site generators require managing Node.js environments, `package.json` dependencies, build toolchains, and hydration runtimes. 

### Why Choose Boris?
- **Zero Toolchain Fatigue:** Boris is a single standalone binary. No `npm install`, no `node_modules`, no security vulnerability warnings.
- **Fail-Loud Validation:** If a page link or parent reference is broken, Boris halts with exit code `1` during the build before publishing.
- **Single-Source AI Exports:** Native `--rag`, `--context`, and `--llms` exports mean AI tools and LLMs read the exact same validated structure as human readers.

---

## 2. Boris vs. Executable MDX

MDX allows embedding arbitrary JavaScript components inside Markdown. While flexible, MDX introduces security risks, build complexity, and vendor lock-in.

### Why Choose Boris?
- **Rich, Safe Authoring:** Boris supports rich components like callout Aside blocks, wiki-links (`[[getting-started]]`), and transclusion (`{{include includes/shared-tip.md}}`) directly in native Markdown without executing client-side or build-side JavaScript.
- **Closed Frontmatter Grammar:** Enforces a strict 5-key frontmatter contract (`id`, `title`, `parent`, `status`, `tags`). Malformed or legacy keys raise clear diagnostic errors (`EFRONTMATTER`) instead of silently ignoring bad fields.

---

## 3. Boris vs. Plain Markdown Repositories

Uncompiled Markdown folders in git repositories lack navigation menus, breadcrumbs, search, and validation.

### Why Choose Boris?
- **Complete Static Sites:** Turns plain text files into responsive HTML sites with sidebar navigation, breadcrumbs, in-page tables of contents, and search.
- **Zero Broken Links:** Guarantees that every internal wiki-link and parent hierarchy link resolves to an existing page before committing build outputs.

---

## Next Steps

- [[getting-started|Getting Started]] — Build your first site in 5 minutes.
- [[technology-and-rationale|Technology & Rationale]] — Deep dive into Zig, in-process ApexMarkdown, and memory design.
- [[guides/overview|Content Model & Pipeline]] — Learn how Trunk/Satellite page graphs operate.
