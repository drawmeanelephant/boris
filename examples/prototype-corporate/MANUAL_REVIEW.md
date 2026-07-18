# Manual Review - Ambiguous & Unsupported DOM Elements (Corporate Theme)

This report documents all interactive, custom, or ambiguous DOM elements from the Google Stitch screens in the Modern Corporate theme project (`9485581018269572800`) that do not directly map to static Boris compiler layout slots. Following our strict zero-dependency, zero-JS constraints, these elements have been preserved in the HTML structure but are documented here for manual review.

---

## 1. Top Header Search Bar with Keyboard Shortcuts
- **HTML Element:**
  ```html
  <div class="relative group">
    <div class="absolute inset-y-0 left-3 flex items-center pointer-events-none text-on-surface-variant">
      <span class="material-symbols-outlined text-[20px]">search</span>
    </div>
    <input class="bg-surface-container-low border-none rounded-full pl-10 pr-16 py-2 text-body-sm font-body-sm focus:ring-2 focus:ring-primary-container w-[280px] transition-all" placeholder="Search documentation..." type="text"/>
    <div class="absolute inset-y-0 right-3 flex items-center pointer-events-none">
      <kbd class="font-label-caps text-label-caps bg-surface-variant px-1.5 py-0.5 rounded text-on-surface-variant">⌘K</kbd>
    </div>
  </div>
  ```
- **Context:** Stitch renders a rounded search bar in the top header with a visual `⌘K` keyboard shortcut badge.
- **Static Boris Mapping:** Unsupported. Purely visual placeholder. Statically, there is no search index, and the `⌘K` keyboard trigger event is not wired up without JavaScript.
- **Recommendation:** Retain as a premium layout placeholder.

---

## 2. Interactive Code Copy Button
- **HTML Element:**
  ```html
  <button class="copy-btn">Copy</button>
  ```
- **Context:** Every `.code-block` contains an overlay "Copy" button that appears on hover, mimicking the original design.
- **Static Boris Mapping:** Unsupported. Purely visual placeholder. Since the theme is strictly zero-JS, clicking this button does not copy text to the system clipboard.
- **Recommendation:** Preserve the button and its hover CSS rules. If clipboard copy is required, it can be wired up in a subsequent stage using a tiny, self-contained inline script.

---

## 3. Light / Dark Theme & Language Selection Buttons
- **HTML Elements:**
  ```html
  <button class="icon-btn">
    <svg class="w-6" ...><path d="M20.354 15.354A9 9 0 018.646..."></path></svg>
  </button>
  <button class="icon-btn">
    <svg class="w-6" ...><path d="M12 2a10 10..."></path></svg>
  </button>
  ```
- **Context:** Two icon buttons (a moon icon and a globe icon) in the header represent theme toggles and language selection.
- **Static Boris Mapping:** Unsupported. Since we have a strict zero-JS constraint, clicking them does not trigger dynamic theme or translation switching.
- **Recommendation:** Retain for high layout fidelity.

---

## 4. Sidebar "Download SDK" CTA Button
- **HTML Element:**
  ```html
  <button class="w-full bg-primary text-on-primary py-sm px-md rounded-lg font-body-sm text-body-sm font-medium hover:bg-primary-container transition-all flex items-center justify-center gap-2">
    Download SDK
  </button>
  ```
- **Context:** An eye-catching blue call-to-action button placed at the bottom of the sidebar.
- **Static Boris Mapping:** Unsupported. It is rendered statically in the sidebar, but doesn't have an active link.
- **Recommendation:** Keep as a placeholder or convert to a static anchor `<a>` linking to an SDK download file in future deployments.
