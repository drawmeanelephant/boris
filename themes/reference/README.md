# Reference

Accessibility-forward documentation theme. Skip link, named landmarks,
visible focus, dark system preference, reduced motion, print. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Assets: local CSS and mark SVG. System Palatino/Georgia serif + UI sans.
- Sample site: [`examples/reference-site/`](../../examples/reference-site/)

```bash
./zig-out/bin/boris \
  --input examples/reference-site/content \
  --theme themes/reference \
  --layout-rule default id:index themes/reference/layouts/home.html \
  --layout-rule default role:trunk themes/reference/layouts/section.html \
  --html-dir test-output/reference \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | Every layout, after the article, labelled "Related pages" / "Pages that link here" with a kind pill. The wrapper is `data-boris-search-exclude` so linked titles stay out of this page's search text. Pages with no relations emit nothing. |
| `{{tags}}` | Intentionally absent. `{{metadata}}` already prints tags in the metadata strip; a second chip list would repeat them, and this docs voice is not list-driven. |
| `{{parent}}` | Intentionally absent. `{{breadcrumb}}` already links the parent on `main` and `section`; `home` serves the `index` trunk, where the slot is always empty. |
| `{{page-status}}` | Intentionally absent. The metadata strip states the status as text; the theme has no badge chrome that would add anything. |
