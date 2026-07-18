# Manual Review - Ambiguous & Unsupported DOM Elements

This report documents all interactive, custom, or ambiguous DOM elements from the Google Stitch screens that do not directly map to static Boris compiler layout slots. Following our strict zero-dependency, zero-JS constraints, these elements have been preserved in the HTML structure but are documented here for manual review.

---

## 1. Top Header Search Bar
- **HTML Element:**
  ```html
  <div class="search-container">
    <svg class="search-icon" ...>...</svg>
    <input class="search-input" placeholder="Search..." type="text"/>
  </div>
  ```
- **Context:** Stitch renders an interactive search text input in the top header.
- **Static Boris Mapping:** Unsupported. Purely visual placeholder in the layout. Statically, there is no search index or search backend compiled into the pages.
- **Recommendation:** Keep as a static layout placeholder. If search is required in the future, it can be wired to a static index search client (like Pagefind) which compiles index files alongside the HTML.

---

## 2. Interactive Code Copy Button
- **HTML Element:**
  ```html
  <button class="copy-btn">Copy</button>
  ```
- **Context:** Every `.code-block` contains an overlay "Copy" button that appears on hover.
- **Static Boris Mapping:** Unsupported. Purely visual placeholder. Since the theme is strictly zero-JS, clicking this button does not copy text to the system clipboard.
- **Recommendation:** Preserve the button and its hover CSS rules so that the design remains identical. In a future phase, a tiny, self-contained 3-line inline JavaScript handler can be added to restore copy functionality without any external dependencies.

---

## 3. Light / Dark Theme Toggle Button
- **HTML Element:**
  ```html
  <button class="icon-btn">
    <svg class="w-6" ...><path d="M20.354 15.354A9 9 0 018.646 3.646..."></path></svg>
  </button>
  ```
- **Context:** A moon icon button in the header actions toggles dark/light modes.
- **Static Boris Mapping:** Unsupported. Since we have a strict zero-JS constraint, clicking the toggle does not switch the `<html>` or `<body>` classes between `light` and `dark`.
- **Recommendation:** Keep the toggle icon as a premium visual element. Dark mode in Boris can be compiled as a separate, distinct dark stylesheet theme or respect system preferences via CSS `@media (prefers-color-scheme: dark)`.

---

## 4. Console/Shell Action Button
- **HTML Element:**
  ```html
  <button class="icon-btn">
    <svg class="w-6" ...><path d="M8 9l3 3..."></path></svg>
  </button>
  ```
- **Context:** A terminal icon button in the top right header.
- **Static Boris Mapping:** Unsupported. Visual placeholder only.
- **Recommendation:** Retain for layout fidelity.

---

## 5. Header Active State Links
- **HTML Element:**
  ```html
  <div class="header-links">
    <a class="header-link active" href="#">Documentation</a>
    <a class="header-link" href="#">Reference</a>
    ...
  </div>
  ```
- **Context:** Top-level navigation items like Reference, Guides, etc., with `.active` border highlights.
- **Static Boris Mapping:** Partial. Static Boris compilations are scoped to the current documentation space, meaning the top links are hardcoded static anchors. The `.active` class highlight cannot be toggled dynamically on compile time unless we define separate layouts for different subsections of the site.
- **Recommendation:** Retain as hardcoded header anchors.
