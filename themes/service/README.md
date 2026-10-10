# Service

Public-service information design. Inspired by GOV.UK's restraint; the
CSS is original. Not GOV.UK Frontend. See
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/studies-site/)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/service \
  --layout-rule default id:index themes/service/layouts/home.html \
  --layout-rule default role:trunk themes/service/layouts/section.html \
  --html-dir test-output/service \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>` (already present). |
| `{{relations}}` / `{{backlinks}}` | Every layout (already present), now as "Related content" / "Linked from" blocks under a blue rule, each link captioned with its kind, inside a `data-boris-search-exclude` wrapper. Pages with no relations emit nothing. |
| `{{page-status}}` | Every layout, as `<body data-status="…">`. The Status entry of the metadata line becomes a tag in the public-service style: yellow for draft, green for published, grey for archived. |
| `{{tags}}` | Intentionally absent. Public-service pages are found by task and section, not by tag; the metadata line still lists tags. |
| `{{parent}}` | Intentionally absent. `main` and `section` render `{{breadcrumb}}`, which already links the parent; `home` serves the `index` trunk. |

## Known limitation: browser-tab title

Every layout spends its one `{{title}}` slot on the visible `<h1>`, so the
document `<title>` is the static word "Service" on every page. A slot may
appear at most once per layout
([`templating-and-themes.md`](https://github.com/drawmeanelephant/boris/blob/main/docs/contracts/templating-and-themes.md)
§3), and moving `{{title}}` into `<title>` would leave the page without its
heading. This needs a design decision (see `ACCESSIBILITY.md`). Search is
not affected: the layout `<h1>` carries `data-boris-search-title="layout"`,
so `_boris/search/search-index.json` titles each page by its own title even
when the content has no heading.
