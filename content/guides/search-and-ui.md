---
title: Search & Browser UI
parent: guides/overview
status: published
tags: [guides, search, ui]
---

# Search & Browser UI

Boris provides a fast, client-side full-text search engine. This guide explains how HTML search indexing operates as a standalone tool, how layout marker tokens work, and how to enable the search modal in custom layouts.

<Aside kind="warning">

**Crucial Gotcha (Documentation Ore):** Running `./zig-out/bin/boris` compiles your static HTML site but **does not automatically build the search index**. The search index tool is a separate standalone Zig binary. You must run `zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search` after rendering HTML.

</Aside>

---

## How Search Indexing Works

The Boris search indexer reads the **rendered HTML output**, not the Markdown source files or JSON IR. By indexing rendered HTML, it captures the exact text visible to human readers while extracting:

- Page titles (`<title>` and `<h1>`)
- Section heading text and fragment IDs (`<h2 id="...">`, `<h3 id="...">`) for deep-linking
- Main body prose text
- Code block contents (stored separately for targeted query scoring)

Elements marked with search exclusion markers, as well as navigation menus, headers, and footers, are automatically omitted from indexing.

The indexer outputs a single deterministic JSON file:

```text
dist/_boris/search/search-index.json
```

---

## Running the Indexer

Execute the HTML build first, followed by the search indexer:

```bash
# 1. Build HTML
./zig-out/bin/boris --theme examples/prototype-corporate --html-dir dist

# 2. Build Search Index
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

The indexer recursively inspects `.html` files under `--root`, excludes `--out` to prevent indexing the output JSON itself, and atomically generates `search-index.json`.

---

## Layout Data Attributes

### 1. Document Root Marker: `data-search-root`
Tag your layout's main content area with the search root attribute so the indexer extracts prose from the main body:

```html
<main data-search-root>
  {{content}}
</main>
```

If omitted, the indexer falls back to searching `<main>`, then `<body>`.

### 2. Exclusion Marker: `data-search-exclude`
Exclude navigation elements, version notices, or dynamic elements from indexing:

```html
<div data-search-exclude>
  This content will not be indexed.
</div>
```

---

## Client-Side Search UI Integration

To enable full-text search in your theme layout:

```html
<div data-boris-search-ui>
  <form role="search">
    <input id="site-search-input" name="q" type="search" autocomplete="off" placeholder="Search docs (Press '/' to focus)...">
    <p data-boris-search-status role="status" aria-live="polite"></p>
    <ol data-boris-search-results aria-label="Search results"></ol>
  </form>
</div>
```

### Search Script Features:
- Fetches `/_boris/search/search-index.json` on initial focus/keystroke.
- Scores matches weighted by heading match > prose match > code match.
- Keyboard navigation: `/` focuses input; `Escape` clears search and closes result modal.
- Zero JavaScript Fallback: If JavaScript is disabled, navigation menus and breadcrumbs remain 100% functional.

---

## Next Steps

- [[guides/themes-and-layouts|Themes & Layouts]] — Creating HTML templates with Boris layout tokens.
- [[reference/outputs|Outputs Reference]] — Schema specification for `search-index.json`.
