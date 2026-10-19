# Accessibility notes

What Blueprint guarantees, checked against the built output and
`assets/css/blueprint.css`. Blueprint uses real landmarks, one native
disclosure, and generated links — the framework look is CSS, not a
simulated application.

- Every layout starts with a skip link to `main#main-content`
  (`tabindex="-1"`), and each page keeps `header`, `main`, and `footer`
  landmarks. The site rail is a `<details>` disclosure whose summary is a
  real focusable control; the compiler's own `nav aria-label="Site"`,
  `"Breadcrumb"`, `"Children"`, and `"On this page"` landmarks survive
  inside the rails and content.
- `:focus-visible` is a `0.1875rem` ring in `--focus-ring-color`
  (`color-mix` of the primary solid): a visible shape change, never
  color-only. It applies to links, the disclosure summary, and every
  author-added `.btn`.
- Color intent is always paired with text. Status chips keep their field
  labels (`Status`, `Parent`, `Tags`); relation chips print the relation
  kind as monospace text from `data-relation-kind`, not an icon; admonition
  titles stay visible text over their tinted surface.
- Contrast is maintained by construction: each `--*-fg` token is chosen
  against its `--*-bg-subtle` pair in both `light-dark()` modes — e.g.
  `--blue-700` on `--blue-100` in light mode and `--blue-300` on
  `--blue-900` in dark. Muted text (`--fg-muted`) is reserved for labels,
  breadcrumbs, and rail copy, not sentences.
- The nav rail is a `<details open>`: it starts expanded (nothing hides
  behind a toggle) and collapses cleanly for a reader who closes it. No
  viewport-dependent disclosure state, so no surprise at any width.
- `prefers-reduced-motion` removes the details animation and smooth
  scrolling entirely. The `::details-content` height transition is the
  only motion in the theme.
- Print drops the topbar, rails, footer, parent link, and relation blocks,
  resets to black on white, and underlines links.

## Known constraints

- The `light-dark()` / `oklch()` / `color-mix()` floor (Chrome/Edge 130+,
  Firefox 132+, Safari 18+) is deliberate — it matches the Bootstrap 6
  alpha surface this theme takes its grammar from. Engines below the floor
  ignore the declarations they cannot parse; content stays readable but
  the palette may not apply.
- `backdrop-filter` on the topbar is decorative: if unsupported, the bar
  is simply more opaque.
