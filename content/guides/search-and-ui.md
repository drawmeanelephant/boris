---
title: Search & Browser UI
parent: guides/overview
status: published
tags: [guides, search, ui]
---

# Search & Browser UI

Boris provides a fast, client-side full-text search engine. This guide explains how HTML search indexing works, how layout marker attributes work, and how to enable the search UI in custom layouts.

<Aside kind="info">

**The compiler builds the search index for you.** Running `./zig-out/bin/boris` writes `dist/_boris/search/search-index.json` as part of the same staged commit as the HTML — no extra step is required. One producer serves both paths: the compiler passes its staged live-page overlay to the same extractor that backs the standalone CLI. Reach for the standalone CLI when you need to index a rendered tree Boris did not build, or to re-index one in place.

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

## Building the index

An ordinary build already produces the index:

```bash
./zig-out/bin/boris --theme examples/prototype-corporate --html-dir dist
# writes dist/**.html and dist/_boris/search/search-index.json
```

To index a rendered tree Boris did not build, or to re-index one in place, run the standalone CLI:

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

The CLI recursively inspects `.html` files under `--root`, excludes `--out` to prevent indexing the output JSON itself, and atomically generates `search-index.json`. Pass `--require-root-marker` to fail any page missing an explicit root marker instead of falling back.

---

## Layout Data Attributes

### 1. Document root marker
Tag your layout's main content area with the search root attribute so the indexer extracts prose from the main body:

```html
<main data-boris-search-root>
  {{content}}
</main>
```

If omitted, the indexer falls back to searching `<main>`, then `<body>`.

### 2. Exclusion marker
Exclude navigation elements, version notices, or dynamic elements from indexing:

```html
<div data-boris-search-exclude>
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
- Fetches `_boris/search/search-index.json` relative to the rendered site root (derived from the theme stylesheet's page-relative `assets/` href in the managed layouts).
- Scores matches weighted by heading match > prose match > code match.
- Keyboard navigation: `/` focuses input; `Escape` clears search and closes result modal.
- Zero JavaScript Fallback: If JavaScript is disabled, navigation menus and breadcrumbs remain fully functional.

### Hosting assumptions

Search is a same-origin browser feature:

- Serve the rendered root over HTTP(S). Opening nested pages via `file://` can still show content, but the search UI needs a real origin that can `fetch` the index.
- Deploy the whole rendered tree together so `_boris/search/search-index.json` sits beside the HTML pages.
- Managed and prototype layouts resolve the index and result links relative to the site root using the theme asset prefix, so URL-prefix deploys and nested `{entity_id}.html` paths work when the full tree is published. Root-absolute `/_boris/...` URLs are not required.
- Rebuild the index after HTML changes; stale HTML without a matching index yields "Search index unavailable."

---

## Next Steps

- [[guides/themes-and-layouts|Themes & Layouts]] — Creating HTML templates with Boris layout tokens.
- [[reference/outputs|Outputs Reference]] — Schema specification for `search-index.json`.
