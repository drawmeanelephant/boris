# Manual Review — Minimalist theme layout (`layouts/main.html`)

This report documents the interactive and custom DOM elements in the
Minimalist theme layout that do not directly map to static Boris compiler
layout slots. The layout ships **no scripts at all** — the search input and
the two header icon buttons are static, visual-only placeholders, and every
control carries an accessible name.

Element inventory (what the shipped layout actually contains):

1. Header search input — **static placeholder**, accessible name (see §1).
2. Theme toggle + console icon buttons — **static placeholders**, accessible
   names, no behavior (see §2).
3. Header links — static anchors (see §3).

The earlier Stitch export's per-code-block "Copy" buttons are **not present**
in the shipped layout and are not documented here.

---

## 1. Header search input (static placeholder)

- **HTML element:** `.search-container` with a search icon and text input:
  ```html
  <div class="search-container">
    <svg class="search-icon">…</svg>
    <input class="search-input" placeholder="Search..." type="text" aria-label="Search"/>
  </div>
  ```
- **Context:** a search field in the top header mirroring the reference design.
- **Static mapping:** unsupported — there is no `data-boris-search-ui`, no
  search form, and no script in this layout, so typing does nothing. The
  `aria-label="Search"` gives the field an accessible name.
- **Recommendation:** keep as a static layout placeholder. To make it real,
  adopt the Corporate prototype's `data-boris-search-ui` integration (form →
  `_boris/search/`, live results from the compiled search index).

## 2. Theme toggle + console icon buttons (static placeholders)

- **HTML elements:** two `.icon-btn` buttons, each with an accessible name and
  an explicit static marker:
  ```html
  <button class="icon-btn" aria-label="Toggle theme" title="Static showcase control">…moon svg…</button>
  <button class="icon-btn" aria-label="Console" title="Static showcase control">…terminal svg…</button>
  ```
- **Context:** header actions mimicking dark-mode and console/shell controls.
- **Static mapping:** unsupported — no JavaScript switches `<html>`'s `light`
  class or opens a console; clicking is a no-op. The buttons are named for
  assistive technology and marked as static so the lack of behavior is
  discoverable.
- **Recommendation:** retain for layout fidelity. Dark mode could be compiled
  as a separate dark stylesheet or via `@media (prefers-color-scheme: dark)`.

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
