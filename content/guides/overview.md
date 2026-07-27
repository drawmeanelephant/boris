---
title: Content Model & Pipeline
parent: guides
status: published
tags: [guides, architecture, pipeline]
---

# Plain English Mental Model & Pipeline

Boris treats your documentation as a **validated directed graph**, not an arbitrary pile of Markdown files. Understanding this mental model clarifies how Boris operates and why parent relationships and supported internal references fail loudly before publish.

<Aside kind="info">

**The Mental Model in Plain English:**  
Think of Boris as a compiler for your site's structure. Every `.md` file is a node in a tree. You explicitly state each page's parent node using `parent: <id>`. Before generating any HTML or machine packages, Boris freezes the whole tree, verifies that every parent exists and that supported Boris internal references (wiki-links, includes, and related graph edges) resolve. External URLs, arbitrary raw HTML links, and every possible page reference are outside that guarantee. If a validated relationship is missing or cyclic, Boris stops and points at the exact error. Once validation passes, it renders the requested output cleanly and predictably.

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
[ 4. RESET ]  Free per-page arena scratch after each page publish
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
Boris frees the per-page arena allocator scratch after publishing each page. Durable metadata (titles, parents, paths) lives in a long-lived `PageDb` for the rest of the run. Boris does **not** claim flat process RSS across large builds; the supported guarantee is that per-page scratch is reset after each page.

---

## Wiki-Links and Snippet Includes

Boris processes two content directives during the pipeline before Markdown parsing:

### Wiki-Links
Link directly to any page by its entity ID:

```markdown
See [[guides/building-pages|Building Pages]] for details on page construction.
```

If `guides/building-pages` does not exist as a page in `content/`, Boris catches it during the **Roll** phase and stops the build with `EREFERENCEMISSING`.

### Snippet Includes
Transclude shared content snippets from `content/includes/`:

```markdown
{{include includes/shared-tip.md}}
```

Files under `content/includes/` are transcluded in-place into the host page before rendering. They do not produce standalone pages in the output directory.

---

## Single-Source Multi-Output Alignment

HTML, JSON IR, RAG packages, AI Context Bundles, and `llms.txt` all start from the same validated content graph **when generated from the same source revision**. They are separate invocations, so alignment requires running the desired exporters against that shared revision:
- The sidebar navigation in HTML matches the graph in JSON IR from the same revision.
- The RAG corpus contains the same published pages as the HTML site from the same revision.
- The `llms.txt` file reflects the published hierarchy from the same revision.

Rendered-site search is a separate standalone tool that indexes the HTML output after it is built.

---

## Next Steps

- [[guides/trunk-satellite|Trunk & Satellite Graph Rules]] — Detailed rules for graph structure and parent links.
- [[guides/search-and-ui|Search & Layout UI]] — How layouts, theme markers, and search indices operate.
- [[guides/rag-export|RAG & Machine Export]] — Generating outputs for AI agents and LLM tools.
- [[reference/diagnostics|Diagnostics Reference]] — Diagnostic codes (`EFRONTMATTER`, `EPARENTMISSING`, `EREFERENCEMISSING`, `EINCLUDEMISSING`) and troubleshooting.
