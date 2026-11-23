# Accessibility notes

What Blueprint guarantees, checked against built output from its layouts
and `assets/css/blueprint.css`.
Blueprint uses real landmarks, native controls, and the compiler's own
generated links. The docs-site behavior is CSS, not a simulated
application.

- Every layout starts with a skip link to `main#main-content`
  (`tabindex="-1"`). Each page keeps `header`, `main`, and `footer`
  landmarks. The sidebar is an `aside` labelled "Documentation", and the
  compiler's `nav aria-label="Site"`, `"Breadcrumb"`, `"Children"`,
  `"Parent"`, and `"On this page"` landmarks survive inside it and the
  content.
- The mobile drawer and the narrow-screen outline are each a real checkbox
  with a visible `<label>` ("Menu", "On this page"). The checkbox stays in
  the tab order, Space toggles it, and its focus ring is drawn on the
  label. The drawer checkbox carries `aria-controls="bp-sidebar"`. No
  script holds the open or closed state.
- `:focus-visible` is a `0.1875rem` ring in `--focus-ring-color` (a
  `color-mix` of the primary solid). It is a shape change, never color
  alone. "See also" cards draw the ring around the whole card when their
  link has focus.
- Color intent is always paired with text. The status pill renders real DOM
  text (`{{page-status}}`: Draft, Published, or Archived), and draft and
  archived pages also get a text banner. Relation cards print their kind
  ("Related", "Builds on", "Linked from"). Admonition titles stay visible text,
  and decorative glyphs (admonition icons, tag `#`, step counters, button and
  parent arrows) use empty CSS alt text (`content: "…" / ""`) with a
  single-value fallback.
- The current page in the sidebar has `aria-current="page"` from the
  compiler. The theme adds a tinted background and, for leaf pages, a
  thicker accent bar, so the state does not depend on hue. Under
  `forced-colors: active`, focus rings and the current link use `Highlight`
  outlines, tag pills and the focused skip link gain `CanvasText` borders
  (preserving base borders on cards and callouts), and the hero heading drops
  its gradient text fill so text remains visible.
- Contrast holds by construction. Each `--*-fg` token is chosen against
  its `--*-bg-subtle` pair in both `light-dark()` modes. Muted text
  (`--fg-muted`) is reserved for labels, breadcrumbs, and rail copy, not
  body sentences.
- Code blocks and tables scroll horizontally inside their own box, so a
  long line never widens the page at 320px. The compiler's `.table-viewport`
  wrapper is a focusable region with `aria-label="Table data"`.
- Print wraps long code lines without forced hyphenation and sets tables
  to full width with wrapping cells so no column clips on paper.
- The search entry point is a labelled `role="search"` form. The status
  line is an `aria-live="polite"` region that is clipped, not
  `display: none`, while the panel is closed, so updates are still
  announced. Without JavaScript, a `<noscript>` note points to the
  sidebar, and a submitted search lands on `assets/search.html` — a
  static page that explains the fallback — rather than a missing route.
- `prefers-reduced-motion` removes the drawer slide, the `<Details>`
  height animation, hover nudges, and smooth scrolling.
- Print drops the header, sidebar, outline, footer, section listings, and
  relation cards. It prints black on white, wraps code, opens `<Details>`
  bodies where `::details-content` is supported, and prints each external
  link's URL.

## Known constraints

- The floor is `light-dark()`, `oklch()`, `color-mix()`, and `:has()`:
  Chrome/Edge 131+, Firefox 132+, Safari 18+. Engines below the floor
  ignore declarations they cannot parse. Content stays readable, but the
  palette and the drawer may not apply.
- The checkbox pattern exposes the drawer toggle as a checkbox ("Menu,
  checkbox, not checked"), not as a disclosure button. A native
  `<details>` cannot be open on wide screens and closed on narrow ones
  without script, so the checkbox is the CSS-only choice.
- The brand link gets its page-relative `href` from the search script. No
  layout helper emits the site root. Without JavaScript, the brand is
  plain text, and the sidebar's first link goes home.
- `backdrop-filter` on the header is decorative. If unsupported, the bar
  is simply more opaque.
