# lab

Dark-first lab-terminal documentation theme with three persisted color modes
(`dark`, `light`, `pride`) cycled by a header toggle. The initial mode follows
`prefers-color-scheme` and is applied by a tiny pre-paint bootstrap in
`<head>`, so there is no light/dark flash on navigation.

- Closed slot vocabulary, including `{{metadata}}`, the graph panel
  (`{{relations}}` / `{{children}}` / `{{backlinks}}`), and `{{toc}}`.
- Search uses the first-party inline rendered-search consumer with the
  documented `data-boris-search-*` hooks; no `<script src>`, no vendored
  JavaScript.
- `layouts/print.html` is an optional named print shape (light-on-paper, on
  screen and in print); select it with a `--layout-rule` when wanted.
  `@media print` on `main.html` prints the same paper palette from any of
  the three modes.
- No motion is emitted; a `prefers-reduced-motion` guard still pins scroll
  behavior, transitions, and animations off so later edits cannot add motion
  for users who asked for none. Visible `:focus-visible`, a skip link, and a
  print pass are included. Details: [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

Select it with `--theme themes/lab`. A specimen site lives under
[`examples/lab-site/`](../../examples/lab-site/).

## Intentionally absent slots

- `{{tags}}` — `{{metadata}}` already prints Tags in the dashed terminal
  block above the content. A second list would repeat it.
- `{{parent}}` — the breadcrumb at the top of `main` already links the
  parent, and the graph panel lists children.
- `{{page-status}}` — Status is already text in `{{metadata}}`. The three
  color modes are the theme's only stateful styling.

`layouts/print.html` deliberately has no skip link, navigation, or graph
panel: it is a single article with nothing to skip past.
