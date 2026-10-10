# Columns

Boxed, CSS-only documentation. Inspired by Bulma's component vocabulary;
the CSS is original. Not Bulma.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/columns \
  --layout-rule default id:index themes/columns/layouts/home.html \
  --layout-rule default role:trunk themes/columns/layouts/section.html \
  --html-dir test-output/columns \
  --quiet
```

## Slot coverage

All three layouts carry `{{relations}}` and `{{backlinks}}`, labelled
"Related" and "Linked from" in menu-label headings, with the relation kind as a rounded tag. Both emit nothing on a page without semantic
relations.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags in the content header. A second
  per-tag list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` already links the parent on `main` and
  `section`; the home page is a Trunk and has no parent.
- `{{page-status}}` — Status is already text in `{{metadata}}`. This
  documentation shell does not add a draft badge.

## Known limitation: browser-tab title

Every layout spends its one `{{title}}` slot on the visible `<h1>`, so the
document `<title>` is the static word "Columns" on every page. A slot may
appear at most once per layout
([`templating-and-themes.md`](../../docs/contracts/templating-and-themes.md)
§3), and moving `{{title}}` into `<title>` would leave the page without its
heading. Search is not affected: the layout `<h1>` carries
`data-boris-search-title="layout"`, so `_boris/search/search-index.json`
titles each page by its own title even when the content has no heading.
