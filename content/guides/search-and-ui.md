---
title: Search & Browser UI
parent: guides/overview
status: published
tags: [guides, search, ui]
---

<p class="eyebrow">Rendered search</p>

# Search & Browser UI {#search-and-ui}

Rendered-site search is part of the normal HTML publication path. The compiler
extracts the committed HTML page set into one deterministic search artifact and
the managed Boris layout provides a small browser UI with a no-JavaScript
navigation fallback.

<Aside kind="info">

For a normal Boris build, do **not** run the standalone search-index tool after
every build. Use that developer tool only when you need to index a rendered
HTML tree Boris did not build, or to replace the index in a tooling workflow.

</Aside>

## The published artifact

For a target rooted at `dist/`, the compiler publishes:

```text
dist/_boris/search/search-index.json
```

The producer reads rendered HTML, not Markdown, IR, or RAG. It records page
paths, titles, rendered headings and fragments, searchable prose, and code in
the v1 `boris-rendered-search-index` format. Navigation, footers, layout
`<header>`/`<aside>` chrome outside a declared content root, executable
elements, and marked exclusions are not indexed.

## Normal build

```bash
./zig-out/bin/boris build --quiet
```

The search artifact is staged and committed with the HTML target. Rebuilding
after a content or layout change refreshes it as part of that target
publication. Deploy the whole target tree together so the pages and
`_boris/search/search-index.json` come from the same build.

## Standalone developer tool

To index a rendered tree that Boris did not build, use the separate tool:

```bash
zig build --build-file tools/search-index/build.zig run -- \
  --root=./dist --out=./dist/_boris/search
```

It recursively selects lowercase `.html` files, excludes its output directory
when nested below the root, and writes the v1 JSON artifact atomically. The
tool's exact input-selection and `--require-root-marker` behavior belongs to
the [rendered-search contract](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/rendered-search.md).

## Layout hooks

A custom layout can identify the main searchable body and opt out regions:

```html
<main data-boris-search-root>
  {{content}}
</main>

<footer data-boris-search-exclude>
  Do not index this footer.
</footer>

<aside data-boris-search-ignore>
  Shared sidebar chrome.
</aside>
```

`data-boris-search-exclude`, `data-boris-search-ignore`, and
`data-boris-noindex` are equivalent exclusion markers. Example framework
themes use that marker on in-main TOC and sidebar rails so repeated kickers
are not indexed; authored asides inside `{{content}}` stay searchable.
Without a marked root,
the producer falls back to the first `<main>`, then `<article>` or
`role="main"`, then `<body>`. On the body/whole-document fallback, `<header>`
and `<aside>` are skipped as layout chrome. Multiple marked roots fail closed.

## Browser UI

The managed layout includes the search form and consumer script. A custom theme
must provide equivalent UI markup and a consumer for the documented v1 fields;
the compiler does not inject a script into arbitrary layouts.

```html
<section data-boris-search-ui>
  <form role="search">
    <input id="site-search-input" name="q" type="search">
    <button type="submit">Search</button>
    <p data-boris-search-status role="status" aria-live="polite"></p>
    <ol data-boris-search-results aria-label="Search results"></ol>
  </form>
</section>
```

The default consumer checks the artifact format and schema, scores heading,
prose, and code matches, and constructs page-relative result links. `/` focuses
the search field and `Escape` clears it. With JavaScript disabled, the regular
navigation, breadcrumbs, and page content still work.

Producer
: Reads committed HTML. Not Markdown, not IR, not RAG.

Consumer
: Theme-owned. The default layout ships a small script. Custom layouts
  must bring their own.

Fallback
: No JavaScript still has nav, breadcrumbs, and the page body.

## Hosting assumptions

Search uses a same-origin `fetch`, so serve the rendered root over HTTP(S) when
you want the UI. Opening `file://` pages is still useful for reading, but a
browser may block the index request. Publish the complete target tree together;
an HTML tree with a missing or stale search artifact reports that the index is
unavailable.

## Next steps

- [[guides/themes-and-layouts|Themes & Layouts]] — create a custom layout.
- [[reference/outputs|Outputs & Artifacts]] — search schema and publication evidence.
