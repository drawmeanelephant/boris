---
title: Search
status: published
parent: index
tags: [search, javascript]
relations: [relates_to=modes]
---

# Search

Search is the first-party inline consumer from the default theme, adapted to
the lab dropdown panel and the documented `data-boris-search-*` hooks. There
is no `<script src>` and no vendored JavaScript.

```html
<div class="search" data-boris-search-ui>
  <form class="search-form" data-boris-search-form role="search">
    <input type="search" id="site-search-input" name="q">
  </form>
  <div class="search-panel" data-boris-search-panel hidden></div>
</div>
```

1. The consumer fetches `_boris/search/search-index.json` relative to the
   site root.
2. It validates the `boris-rendered-search-index` envelope and schema version
   before trusting any document.
3. Results are scored across title, headings, prose, and code, then capped at
   twelve links.

Without JavaScript the form falls back to the published search route and the
navigation tree remains fully usable. See [[modes]] for how the dropdown
inherits each color mode's tokens.
