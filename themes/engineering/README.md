# Engineering

Dense engineering documentation. Inspired by Primer's boxes and labels;
the CSS is original. Not Primer. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/engineering \
  --layout-rule default id:index themes/engineering/layouts/home.html \
  --layout-rule default role:trunk themes/engineering/layouts/section.html \
  --html-dir test-output/engineering \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | Every layout (already present), now as two nested boxes, "Relations" / "Backlinks", with the raw kind token as a monospace label, inside a `data-boris-search-exclude` wrapper. Pages with no relations emit nothing. |
| `{{page-status}}` | Every layout, as `<body data-status="…">`. The Status entry of the metadata line, directly under the title, renders as a status label with a dot: yellow for draft, green for published, grey for archived, in both colour schemes and in print. The `dashboard` starter relies on this. |
| `{{tags}}` | Intentionally absent. The metadata line lists tags next to the status label; a separate label row would repeat them. |
| `{{parent}}` | Intentionally absent. Every layout except `home` renders `{{breadcrumb}}` at the top of the article, which already links the parent. |

## Known limitation

Every layout spends its one `{{title}}` slot on the visible `<h1>`, so the
document `<title>` is the static word "Engineering" on every page. Moving
`{{title}}` into `<title>` would leave the page without its heading; this
needs a design decision (see `ACCESSIBILITY.md`).
