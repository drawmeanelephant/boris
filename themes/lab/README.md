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
- `layouts/print.html` is an optional named print shape (light-on-paper);
  select it with a `--layout-rule` when wanted.
- No motion is emitted, so `prefers-reduced-motion` has nothing to silence;
  visible `:focus-visible`, a skip link, and a print pass are included.

Select it with `--theme themes/lab`. A specimen site lives under
[`examples/lab-site/`](../../examples/lab-site/).
