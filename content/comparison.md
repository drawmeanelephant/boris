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

| Feature / Goal | Plain Markdown / Wiki | JS Frameworks (Docusaurus, Astro) | Boris Documentation Compiler |
| :--- | :---: | :---: | :--- |
| **Build Runtime** | None (Raw files) | Node.js / npm | **Single native Zig binary** |
| **Build Execution** | N/A | Subprocess / Node pipelines | **In-process C ABI execution**[^speed] |
| **Memory Design** | N/A | Garbage collected JS heap | **Per-page arena scratch reset**[^memory] |
| **Link & Graph Safety** | None | Optional plugins | **Parent & Wiki-Link Validation** |
| **Rich Markdown** | Basic CommonMark | MDX (arbitrary JS) | **Rich ApexMarkdown**: Callouts, footnotes, wiki-links, includes |
| **Full-Text Search** | External service | Bundled JS indexers | **Built-in Standalone Search Indexer** |
| **Machine & AI Exports** | Scraping / plugins | Custom build scripts | **Native Exports**: JSON IR 0.2.0, RAG, Context, `llms.txt` |
| **Client JS Footprint** | None | Varies by framework setup | **Zero Required Client JS** |

Table: Architectural Comparison Matrix

---

## 1. Boris vs. JavaScript Site Generators (Docusaurus, Astro, Starlight)

JavaScript site generators require managing Node.js environments, `package.json` dependencies, build toolchains, and hydration runtimes. 

### Why Choose Boris?
- **Zero Toolchain Fatigue:** Boris is a single standalone binary with zero `node_modules` dependency tree to audit or update.
- **Fail-Loud Validation:** If a parent relationship or supported internal wiki-link is broken, Boris halts with exit code `1` during the build before publishing.
- **Single-Source AI Exports:** Native `--rag`, `--context`, and `--llms` exports mean AI tools and LLMs read the exact same validated structure as human readers when generated from the same source revision.

---

## 2. Boris vs. Executable MDX

MDX allows embedding arbitrary JavaScript components inside Markdown. While flexible, MDX introduces security risks, build complexity, and vendor lock-in.

### Why Choose Boris?
- **Rich, Safe Authoring:** Boris supports rich components like callout Aside blocks (`&lt;Aside kind="tip"&gt;`), wiki-links (`[[getting-started]]`), and transclusion (`{{include includes/shared-tip.md}}`) directly in native Markdown without executing client-side or build-side JavaScript.
- **Closed Frontmatter Grammar:** Enforces a strict 5-key frontmatter contract (`id`, `title`, `parent`, `status`, `tags`). Malformed or legacy keys raise clear diagnostic errors (`EFRONTMATTER`) instead of silently ignoring bad fields.

---

## 3. Boris vs. Plain Markdown Repositories

Uncompiled Markdown folders in git repositories lack navigation menus, breadcrumbs, search, and validation.

### Why Choose Boris?
- **Complete Static Sites:** Turns plain text files into responsive HTML sites with sidebar navigation, breadcrumbs, in-page tables of contents, and search.
- **Fail-Loud Link Safety:** Guarantees parent relationships and supported internal wiki-links resolve before committing build outputs.

<Aside kind="tip">
**Migration Path:** Want to evaluate your existing Markdown site? Run `zig build --build-file tools/migration-lab/build.zig run -- --source /path/to/old-site` to inspect your frontmatter and hierarchy before converting.
</Aside>

---

## Next Steps

- [[getting-started|Getting Started]] — Build your first site in 5 minutes.
- [[technology-and-rationale|Technology & Rationale]] — Deep dive into Zig, in-process ApexMarkdown, and memory design.
- [[guides/overview|Content Model & Pipeline]] — Learn how Trunk/Satellite page graphs operate.

[^speed]: Builds use in-process C ABI calls to ApexMarkdown, eliminating per-page subprocess spawning and JS bundler overhead.
[^memory]: Per-page arena allocation ensures that memory scratch space allocated while parsing a page is reset after page emission, keeping memory usage controlled throughout build runs.
