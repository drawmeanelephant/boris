# Showcase

Docs + blog shell with a soft component feel. Hand-authored CSS. DaisyUI
was evaluated and rejected; this sheet is not DaisyUI and must not be
labeled as such. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home`, `section`, `blog`, `main`, `portfolio`
- Assets: local CSS and mark SVG. System UI stack.
- Sample site: [`examples/showcase-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/showcase-site/)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/showcase-site/content \
  --theme themes/showcase \
  --layout-rule default id:index themes/showcase/layouts/home.html \
  --layout-rule default 'glob:blog/*' themes/showcase/layouts/blog.html \
  --layout-rule default role:trunk themes/showcase/layouts/section.html \
  --html-dir test-output/showcase \
  --quiet
```

## Slot coverage

The `portfolio` layout leads with the authored studio introduction and its
compiler-owned child collection, without the generic masthead, full site
index, metadata card or outline. Select it with
`--layout-rule default id:index themes/showcase/layouts/portfolio.html`;
`boris init --type portfolio` declares this rule in its profile.
The collection is labelled "Work & about": About and projects are all direct
children, not a filtered taxonomy or a second hand-maintained list.
Generic home/docs/blog layouts remain unchanged. Only the portfolio layout
loads the extra local `assets/css/portfolio.css`.

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | Every layout, after the article, as two soft cards ("Related" / "Backlinks") with kind badges. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{page-status}}` | Every layout, as `<body data-status="…">`. Generic layouts turn the Status metadata entry into a badge: pink for draft, teal for published, grey for archived. Portfolio omits that metadata chrome. |
| `{{children}}` | Every layout. `home` keeps its generic "Explore" grid; `portfolio` uses "Work & about". `section` and `main` list "In this section", `blog` "More posts". Every children panel is `data-boris-search-exclude` and hides when the page has no children. |
| `{{tags}}` | `blog` only, as `#tag` chips under the metadata card; the duplicate Tags entry in the card is hidden. Docs layouts keep tags inside `{{metadata}}`. |
| `{{parent}}` | Intentionally absent. Generic page layouts render `{{breadcrumb}}`; `home` and `portfolio` serve an index trunk without it. |

## Search

No search UI ships. Each `main` carries `data-boris-search-root`, and
in-main chrome (children panels, outline, side rails, relations) carries
`data-boris-search-exclude`, so the rendered search index Boris emits stays
limited to page prose.
