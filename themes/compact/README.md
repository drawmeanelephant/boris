# Compact

Small-type documentation. Inspired by Chota's scale; this sheet is original
and is not Chota. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home.html` (`id:index`), `main.html`
- Assets: `assets/css/compact.css` (system stack)
- Sample site: [`examples/compact-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/compact-site/)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/compact-site/content \
  --theme themes/compact \
  --layout-rule default id:index themes/compact/layouts/home.html \
  --html-dir test-output/compact \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Both layouts, directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | Both layouts, after the article, as a compact two-column "Related" / "Backlinks" pair with small kind tags. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{tags}}` | Intentionally absent. The metadata strip already lists tags in one line; chips would add height to a theme whose point is density. |
| `{{parent}}` | Intentionally absent. Both layouts render `{{breadcrumb}}`, which already links the parent. |
| `{{page-status}}` | Intentionally absent. The metadata strip states the status in text; compact has no badge chrome. |
