# Boris Documentation Product Spine & Audit

## One-Sentence Product Definition

**Boris is a zero-dependency native static documentation compiler that turns rich Markdown files into validated, searchable HTML documentation sites and machine-ready AI packages from a single source.**

---

## Three Core Product Pillars

1. **Expressive, Native Markdown Authoring**  
   Write clean Markdown with rich built-in components—callout `<Aside>` blocks, footnotes, tables, wiki-links (`[[page-id]]`), and transclusion includes (`{{include snippet.md}}`)—without managing npm packages, JSX imports, or MDX bundlers.

2. **Validated Site Graph & Complete Static Engine**  
   Boris builds complete static documentation sites—not just isolated HTML renders. It enforces explicit page hierarchies (`parent: <id>`) and validates parent chains plus supported internal references before writing files, alongside graph-backed navigation, breadcrumbs, TOC, and optional client-side full-text search.

3. **Single-Source Multi-Output (Human & Machine)**  
   From one frozen, validated content tree, Boris publishes static HTML for human readers, client-side search indices (via `tools/search-index`), JSON IR schemas for developer tooling (`--out`), RAG corpora (`--rag`) for vector DBs, AI Context Bundles (`--context`) for LLM prompts, and standard `llms.txt` (`--llms`) for crawlers.

---

## Primary Audiences

- **Technical Documentation Authors & Technical Writers**: Want expressive Markdown with callouts, transclusion, and fail-loud parent/wiki-link validation without setting up complex JS site frameworks.
- **Systems Developers & Platform Engineers**: Want a fast, single-binary static site generator with zero runtime dependencies (no Node.js/npm) that runs natively on CI/CD pipelines.
- **AI Tool Integrators & Developer Experience Engineers**: Need structured, deterministic RAG corpora, machine IR, and LLM context bundles generated via dedicated CLI invocations alongside static docs.

---

## Recommended Product Narrative & Hierarchy

The documentation is organized around a 4-stage narrative progression:

```
1. Write Expressive Markdown
   ├── ApexMarkdown Syntax (`guides/apex-markdown.md`)
   └── Callout Asides (`guides/asides.md`)
       │
       ▼
2. Organize as Validated Documentation
   ├── Building & Writing Pages (`guides/building-pages.md`)
   └── Trunk & Satellite Hierarchy (`guides/trunk-satellite.md`)
       │
       ▼
3. Turn into a Polished, Searchable Static Site
   ├── Themes & Layout Templates (`guides/themes-and-layouts.md`)
   └── Search & Browser UI (`guides/search-and-ui.md`)
       │
       ▼
4. Publish Machine-Ready Outputs from the Same Source
   └── RAG & AI Machine Outputs (`guides/rag-export.md`)
```

---

## Comprehensive Page-by-Page Audit Table

| Page Path | Intended Reader | Question Answered | Action Taken Afterward | Primary Capability | Section Category | Leads with Value or Detail? |
|---|---|---|---|---|---|---|
| `content/index.md` | All Readers | What is Boris and why use it? | Navigate to getting started or feature guides | Site Compiler & Multi-Output | Homepage | Leads with **User Value** |
| `content/getting-started.md` | New Users & Agents | How do I build my first site in 5 minutes? | Run 4 commands to produce HTML, search, and AI outputs | Quickstart & CLI | Onboarding | Leads with **User Value** |
| `content/comparison.md` | Decision Makers | Why use Boris instead of Next.js/Astro/MDX/CMS? | Choose Boris for static docs & AI exports | Native Execution & Multi-Output | Comparison | Leads with **User Value** |
| `content/technology-and-rationale.md` | Architects / Engineers | Why is Boris built in Zig with in-process ApexMarkdown? | Understand architectural design choices | Memory Model & In-Process C ABI | Concepts | Leads with **Value & Rationale** |
| `content/guides.md` | Authors & Devs | What guides are available? | Jump to specific guide | Documentation Map | Landing | Leads with **User Value** |
| `content/guides/overview.md` | Authors & Devs | How does Boris organize and validate pages? | Structure pages into parent-child trees | Validated Page Graph | Concepts | Leads with **User Value** |
| `content/guides/apex-markdown.md` | Content Authors | What rich syntax features does Boris Markdown support? | Write tables, footnotes, wiki-links, includes | Rich ApexMarkdown Syntax | Authoring Guides | Leads with **User Value** |
| `content/guides/asides.md` | Content Authors | How do I create callouts and admonitions? | Add `<Aside>` blocks to Markdown | Callout Admonition Components | Authoring Guides | Leads with **User Value** |
| `content/guides/building-pages.md` | Content Authors | How do I create, link, and organize pages? | Write frontmatter and `[[wiki-links]]` | Page Creation & Linking | Authoring Guides | Leads with **User Value** |
| `content/guides/cli-and-modes.md` | Developers / CI | What CLI flags and run modes exist? | Configure watch, parallel `--jobs`, or output flags | Multi-Mode CLI Surface | Guides / Reference | Leads with **User Value** |
| `content/guides/trunk-satellite.md` | Authors & Architects | What are the rules for Trunk and Satellite pages? | Organize multi-branch navigation trees | Graph Hierarchy Validation | Concepts | Leads with **User Value** |
| `content/guides/themes-and-layouts.md` | Designers / Devs | How do I customize site appearance and layouts? | Pass `--theme` or write HTML layout templates | HTML Layout & Theme Engine | Customization | Leads with **User Value** |
| `content/guides/search-and-ui.md` | Frontend / Devs | How do I enable client-side search and UI? | Run standalone search indexer and wire UI | Client-Side Search Engine | Feature Guides | Leads with **User Value** |
| `content/guides/rag-export.md` | AI Developers | How do I generate machine RAG, IR, and llms.txt? | Run `--rag`, `--context`, `--out`, and `--llms` | Machine Output Generators | Machine Exports | Leads with **User Value** |
| `content/guides/migration.md` | System Migrators | How do I migrate existing Markdown/Hugo/Docusaurus sites? | Convert frontmatter and parent links to Boris | Migration Tools | Guides | Leads with **User Value** |
| `content/reference.md` | All Users | Where are the reference specifications? | Navigate to spec manuals | Reference Directory | Reference Landing | Leads with **User Value** |
| `content/reference/commands.md` | Developers / Operators | What are all the exact CLI flags and options? | Look up specific command parameters | Complete CLI Specification | Reference | Leads with **Implementation Detail** |
| `content/reference/frontmatter.md` | Content Authors | What frontmatter keys are accepted? | Format page frontmatter correctly | Closed Frontmatter Grammar | Reference | Leads with **Specification** |
| `content/reference/outputs.md` | Tool Builders | What are the schemas for JSON IR, RAG, and Context? | Parse JSON IR and RAG catalogs programmatically | Machine Output Schemas | Reference | Leads with **Specification** |
| `content/reference/diagnostics.md` | All Users | How do I fix compiler error codes? | Resolve `EFRONTMATTER`, `EPARENTMISSING`, `EREFERENCEMISSING`, `EINCLUDEMISSING` errors | Diagnostic Error Codes | Reference | Leads with **Actionable Fixes** |
| `content/reference/relationships.md` | Authors / Devs | How are page relationship types classified? | Review parent, link, and semantic relations | Relationship Classification | Reference | Leads with **Specification** |

---

## Duplicated or Misplaced Material Remediation

1. **Pipeline Sequence on Homepage**:  
   - *Final Design*: The homepage specimen retains "Load → Roll → Ignite → Reset" as a high-level 4-stage narrative sequence, while detailed memory and C ABI mechanics live in `guides/overview.md` and `technology-and-rationale.md`.

2. **Decoupled Search Index Gotcha**:  
   - *Problem*: Mentioned in multiple pages without a central explanation.
   - *Fix*: Centralize in `guides/search-and-ui.md` and link from `getting-started.md` and `index.md`.

---

## Newly Added & High-Value Pages

1. **`content/comparison.md`**: Created a dedicated comparison document contrasting Boris against general-purpose JavaScript frameworks (Docusaurus, Astro, Next.js), hosted CMS platforms, and plain unvalidated Markdown setups.
