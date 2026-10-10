# Tokens

Fluid custom properties. Inspired by Open Props; the CSS is original.
Not Open Props. System font stack only.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/tokens \
  --layout-rule default id:index themes/tokens/layouts/home.html \
  --layout-rule default role:trunk themes/tokens/layouts/section.html \
  --html-dir test-output/tokens \
  --quiet
```

## Slot coverage

All three layouts carry `{{relations}}` and `{{backlinks}}`, labelled
"Related" and "Linked from" in kicker headings, with the relation kind as a soft pill. Both emit nothing on a page without semantic
relations.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags in the article header. A second
  per-tag list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` already links the parent on `main` and
  `section`; the home page is a Trunk and has no parent.
- `{{page-status}}` — Status is already text in `{{metadata}}`. This
  documentation shell does not add a draft badge.
