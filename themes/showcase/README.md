# Showcase

Docs + blog shell with a soft component feel. Hand-authored CSS. DaisyUI
was evaluated and rejected; this sheet is not DaisyUI and must not be
labeled as such. See [`ACCESSIBILITY.md`](ACCESSIBILITY.md).

- Layouts: `home`, `section`, `blog`, `main`
- Assets: local CSS and mark SVG. System UI stack.
- Sample site: [`examples/showcase-site/`](../../examples/showcase-site/)

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

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | Every layout, after the article, as two soft cards ("Related" / "Backlinks") with kind badges. The wrapper is `data-boris-search-exclude`. Pages with no relations emit nothing. |
| `{{page-status}}` | Every layout, as `<body data-status="…">`. The Status entry of the metadata card becomes a badge in the same family as the navbar badges: pink for draft, teal for published, grey for archived. |
| `{{children}}` | Every layout. On `home` the index page's direct satellites render as a card grid ("Explore") after the prose, so a portfolio index lists its projects without hand-written links; the panel hides when the page has no children. `section` and `main` list "In this section", `blog` "More posts". Every children panel is `data-boris-search-exclude` and hides when the page has no children. |
| `{{tags}}` | `blog` only, as `#tag` chips under the metadata card; the duplicate Tags entry in the card is hidden. Docs layouts keep tags inside `{{metadata}}`. |
| `{{parent}}` | Intentionally absent. Every layout except `home` renders `{{breadcrumb}}`, which already links the parent; `home` serves the `index` trunk. |

## Search

No search UI ships. Each `main` carries `data-boris-search-root`, and
in-main chrome (children panels, outline, side rails, relations) carries
`data-boris-search-exclude`, so the rendered search index Boris emits stays
limited to page prose.
