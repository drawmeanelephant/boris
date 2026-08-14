# Manual Review — Corporate theme layout (`layouts/main.html`)

This report documents the interactive and custom DOM elements in the Corporate
theme layout that do not directly map to static Boris compiler layout slots.
The layout has **no external dependencies** — no CDN, no framework, no remote
assets. Exactly one self-contained inline script ships with the page: the
search integration against the compiled Boris search index. Everything else is
static markup.

Element inventory (what the shipped layout actually contains):

1. Header search — **scripted, functional** (see §1).
2. Theme toggle + settings icon buttons — **static placeholders**, accessible
   names, no behavior (see §2).
3. Header links — static anchors (see §3).

The earlier Stitch export's `⌘K` keyboard badge, per-code-block "Copy"
buttons, and sidebar "Download SDK" CTA are **not present** in the shipped
layout and are not documented here.

---

## 1. Header search (scripted, against the compiled search index)

- **HTML element:** `.search-container[data-boris-search-ui]` wrapping a
  `<form role="search" data-boris-search-form>` with a search input, a live
  status region, and a results list:
  ```html
  <div class="search-container" data-boris-search-ui>
    <form action="_boris/search/" method="get" role="search" data-boris-search-form>
      <input id="site-search-input" class="search-input" name="q" type="search"
             placeholder="Search documentation (Press '/' to focus)..."
             aria-label="Search documentation"/>
      <p class="site-search__status" data-boris-search-status role="status" aria-live="polite"></p>
      <ol class="site-search__results" data-boris-search-results aria-label="Search results"></ol>
    </form>
  </div>
  ```
- **Behavior:** the inline `<script>` wires the search UI to the compiler's
  `_boris/search/search-index.json` (the `<main data-boris-search-root>`
  element makes Boris emit it). It derives the site-root prefix from the
  emitted stylesheet `href`, validates the index (`boris-rendered-search-index`
  schema 1), scores heading/text/code matches, renders up to 12 results with
  excerpts, and announces results through the `aria-live` status region.
  `'/'` focuses the input; `Escape` clears and blurs it; submitting renders
  results in place. No external requests; `credentials: "same-origin"` only.
- **Fallback:** if the index is missing or unreadable, the status region reads
  "Search index unavailable." and the page still renders — the failure is
  contained to the search UI.
- **Static mapping:** not a compiler slot; the search index itself is a
  compiled artifact, but the widget is author markup.

## 2. Theme toggle + settings icon buttons (static placeholders)

- **HTML elements:** two `.icon-btn` buttons, each with an accessible name:
  ```html
  <button class="icon-btn" aria-label="Toggle theme">…moon svg…</button>
  <button class="icon-btn" aria-label="Settings">…gear svg…</button>
  ```
- **Context:** the header actions area mimics theme and settings controls from
  the reference design.
- **Static mapping:** unsupported — no JavaScript toggles `<html>`'s `light`
  class or opens a settings panel. Clicking is a no-op. They are retained for
  layout fidelity and are named for assistive technology.
- **Recommendation:** keep as static placeholders. A theme toggle could be
  wired to the existing `class="light"` root in a later stage, or replaced by
  a `prefers-color-scheme` stylesheet.

## 3. Header links (static anchors)

- **HTML elements:** `.header-links` with four hardcoded anchors:
  ```html
  <a class="header-link active" href="#">Documentation</a>
  <a class="header-link" href="#">Reference</a>
  <a class="header-link" href="#">Guides</a>
  <a class="header-link" href="#">Community</a>
  ```
- **Context:** top-level navigation for the documentation space.
- **Static mapping:** partial — the anchors are hardcoded and `.active` cannot
  move per page without per-section layouts.
- **Recommendation:** retain; replace `href="#"` with real routes when the
  example gains content.
