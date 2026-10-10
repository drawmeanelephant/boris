# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Every layout opens with "Skip to content" targeting
  `#main-content`. The link is white on `#0969da` (5.19:1) in both schemes.
- **Landmarks.** A body-level `header`, one `main`, a labelled "On this
  page" `aside` (or the home rail), and a body-level `footer`. The header
  nav and breadcrumb wrappers are plain `div`s; their former `aria-label`s
  sat on role-less elements and were never announced. The compiler's
  `nav aria-label="Site"` and `nav aria-label="Breadcrumb"` inside them are
  the navigation landmarks.
- **Focus.** `:focus-visible` draws a 0.2rem outline with a 0.2rem offset:
  `#0969da` on light surfaces (5.19:1 on white, 4.88:1 on the canvas) and
  `#4493f8` in dark mode (5.58:1 on `#161b22`). Inside the always-dark header
  the ring is `#58a6ff` (5.80:1 on `#24292f`); the old `#0969da` ring there
  measured 2.82:1.
- **Contrast.** Links `#0969da` are 5.19:1 on white. Dark mode now
  overrides the link colour to `#4493f8` (5.58:1); the previous inherited
  `#0969da` measured 3.33:1 on the dark surface. Status labels: draft
  4.52:1, published 4.56:1, archived 4.63:1 (light); 5.28:1, 6.25:1, and
  4.95:1 (dark).
- **Not colour alone.** The status label keeps its word ("draft") and a dot;
  the visually hidden "Status" term still reaches assistive technology.
  Relation kinds are text labels. Callouts keep their text title, which is
  drawn in the kind colour: note/info `#0969da` (5.19:1 on white), tip
  `#1a7f37` (5.08:1), warning `#9a6700` (4.87:1), danger `#cf222e` (5.36:1);
  dark mode `#4493f8` (5.58:1), `#3fb950` (6.81:1), `#d29922` (6.85:1),
  `#f85149` (5.16:1) on `#161b22`. Before #1049 the note callout had no
  edge and info reused the tip green.
- **Current page.** The header nav marks the compiler's
  `aria-current="page"` link with a coral bar under it (a shape cue, not a
  text colour change).
- **Motion.** `prefers-reduced-motion: reduce` disables smooth scrolling.
- **Print.** `@media print` resets the palette to black on white even for
  dark-mode readers, hides the header, footer, sidebars, and skip link,
  flattens boxes, keeps the status label as a black outline, and wraps code.
- **Narrow screens.** Below 48rem the header stacks, the grid becomes one
  column, and the sidebar stops being sticky.
- **Search hygiene.** `data-boris-search-root` on `main`. The section label,
  the layout `<h1>` (which has no id, so its stored fragment could not
  resolve), the children box, the outline, and relations carry
  `data-boris-search-exclude`. The layout `<h1>` also carries
  `data-boris-search-title="layout"`, so a page with no authored heading is
  indexed under its own title (verified; before #1049 it indexed as
  "Engineering").
- **Known limitation.** The document `<title>` is the static word
  "Engineering" on every page because the layouts use their single
  `{{title}}` slot for the visible `<h1>` (WCAG 2.4.2 Page Titled is not
  met). Recorded for a design decision rather than silently changed.
