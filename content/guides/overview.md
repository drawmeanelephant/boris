---
title: Content Model & Pipeline
parent: guides
status: published
tags: [guides, architecture, pipeline]
---

# Plain English Mental Model & Pipeline

Boris treats your documentation as a **validated directed graph**, not an arbitrary pile of Markdown files. Understanding this mental model clarifies how Boris operates and guarantees zero broken links in production.

<Aside kind="info">

**The Mental Model in Plain English:**  
Think of Boris as a compiler for your site's structure. Every `.md` file is a node in a tree. You explicitly state each page's parent node using `parent: <id>`. Before generating any HTML or machine packages, Boris freezes the whole tree, verifies that every parent exists and every link points to a real target. If anything is missing or cyclic, it stops instantly and points out the exact error line. Once validated, it renders your site and machine exports cleanly and predictably.

</Aside>

---

## Nodes in the Graph: Trunk & Satellite

Every Markdown file under `content/` becomes a graph node identified by its path relative to `content/` (without the `.md` extension).

Trunk Node
: A root page with no `parent` declared. Serves as a top-level anchor of a navigation section (e.g., `index`, `getting-started`, `reference`).

Satellite Node
: A page with a `parent` key declaring its direct parent's Entity ID. Nests under its parent in navigation.

Entity ID
: Canonical node identifier derived from file path relative to `content/` without extension (`content/guides/overview.md` → `guides/overview`).

Graph Freeze
: The moment during the Roll phase when frontmatter and links are validated and frozen in memory before any file is written to disk.

```markdown
---
title: Content Model & Pipeline
parent: guides
status: published
---
```

<Aside kind="warning">

**Frontmatter Rule:** The parent field **must be named `parent`**. Legacy names such as `parent_entry` or `parentEntry` are rejected as invalid frontmatter keys with error code `EFRONTMATTER`.

</Aside>

---

## The Four Pipeline Stages: Load → Roll → Ignite → Reset

Every Boris execution follows a strict 4-stage pipeline, regardless of output mode:

```
[ 1. LOAD ]   Discover all content/ files and includes/
     │
     ▼
[ 2. ROLL ]   Parse YAML frontmatter, resolve parent links, validate graph
     │
     ├────────► [ VALIDATION ERROR? ] ──► Fail loudly (exit code 1), write nothing
     ▼
[ 3. IGNITE ] Route validated graph to requested target (HTML, IR, RAG, Context, llms.txt)
     │
     ▼
[ 4. RESET ]  Free per-page arena scratch memory (flat memory usage)
```

### 1. Load (Discovery)
Boris recursively scans `content/` for `.md` files. Files stored inside `content/includes/` are identified as reusable code/text snippets and excluded from being generated as standalone pages.

### 2. Roll (Graph Resolution & Validation)
Boris parses frontmatter for every page, validates the closed 5-key frontmatter contract (`id`, `title`, `parent`, `status`, `tags`), verifies parent-child hierarchy, builds the site tree, and validates all wiki-links and include statements.  
**Critical Guarantee:** Validation completes *before* any output files are written. If a parent link is missing or cyclic, Boris halts with exit code `1` and outputs a diagnostic error.

### 3. Ignite (Rendering & Emission)
The validated, frozen graph is passed to the requested target emitter:
- **HTML Emitter (default):** Expands includes, rewrites wiki-links to relative `.html` links, invokes in-process ApexMarkdown to convert Markdown to HTML, and splices content into your layout template.
- **IR Emitter (`--out`):** Produces machine-readable JSON manifests, graphs, and page entities under `.boris/`.
- **RAG Emitter (`--rag`):** Produces clean Markdown corpus and catalogs under `rag/` optimized for vector indexing.
- **Context Emitter (`--context`):** Produces a single aggregated context document under `context/`.
- **LLMS Emitter (`--llms`):** Produces `llms.txt` listing all published pages.

### 4. Reset (Scratch Cleanup)
Boris frees the per-page arena allocator scratch memory after rendering each page. Memory consumption remains low and flat even when rendering thousands of pages.

---

## Wiki-Links and Snippet Includes

Boris processes two content directives during the pipeline before Markdown parsing:

### Wiki-Links
Link directly to any page by its entity ID:

```markdown
See [[guides/building-pages|Building Pages]] for details on page construction.
```

If `guides/building-pages` does not exist as a page in `content/`, Boris catches it during the **Roll** phase and stops the build with `EGRAPH`.

### Snippet Includes
Transclude shared content snippets from `content/includes/`:

```markdown
{{include includes/shared-tip.md}}
```

Files under `content/includes/` are transcluded in-place into the host page before rendering. They do not produce standalone pages in the output directory.

---

## Single-Source Multi-Output Guarantee

Because HTML, JSON IR, RAG packages, AI Context Bundles, and `llms.txt` are all emitted from the exact same frozen, validated graph, **all outputs are 100% consistent by definition**:
- The sidebar navigation in HTML matches the graph in JSON IR.
- The RAG corpus contains the exact same published pages as the live HTML site.
- The `llms.txt` file accurately reflects the published hierarchy.

---

## Next Steps

- [[guides/trunk-satellite|Trunk & Satellite Graph Rules]] — Detailed rules for graph structure and parent links.
- [[guides/search-and-ui|Search & Layout UI]] — How layouts, theme markers, and search indices operate.
- [[guides/rag-export|RAG & Machine Export]] — Generating outputs for AI agents and LLM tools.
- [[reference/diagnostics|Diagnostics Reference]] — Diagnostic codes (`EFRONTMATTER`, `EGRAPH`, `EINC`) and troubleshooting.
