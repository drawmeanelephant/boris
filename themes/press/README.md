# Press

Editorial paper, crimson masthead, serif reading. Visual cues come from a
legacy Textpattern reference; this is a Boris-owned theme, not a Textpattern
port or an official adapter.

- Layouts: `home`, `section`, `blog`, `archive`, `main`
- Assets: `assets/css/press.css`, `assets/img/press-mark.svg`
- Fonts: system Palatino/Georgia + UI sans + UI mono. No shipped webfont.
- Sample site: [`examples/press-site/`](../../examples/press-site/)
- Provenance: [`MIGRATION.md`](MIGRATION.md), [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/press-site/content \
  --theme themes/press \
  --layout-rule default id:index themes/press/layouts/home.html \
  --layout-rule default id:guides themes/press/layouts/section.html \
  --layout-rule default id:reference themes/press/layouts/section.html \
  --layout-rule default id:blog themes/press/layouts/blog.html \
  --layout-rule default id:archive themes/press/layouts/archive.html \
  --layout-rule default 'glob:blog/*' themes/press/layouts/blog.html \
  --html-dir test-output/press \
  --quiet
```

## Slot coverage

| Slot | Decision |
|---|---|
| `{{head}}` | Every layout, directly inside `<head>`. |
| `{{relations}}` / `{{backlinks}}` | Every layout, after the article, as a ruled "See also" / "Cited by" pair. The wrapper is `data-boris-search-exclude` so linked titles are not indexed as this page's text. Pages with no relations emit nothing. |
| `{{page-status}}` | Every layout, as `<body data-status="…">`. Draft and archived pages stamp the Status entry of the metadata box like a proof mark; published pages stay plain. |
| `{{tags}}` | `blog` only, as a "Filed under" line under the metadata box; the duplicate Tags entry in the box is hidden. Other layouts keep tags inside `{{metadata}}` because notebook and section pages are not tag-browsed. |
| `{{parent}}` | Intentionally absent. Every layout except `home` renders `{{breadcrumb}}`, which already links the parent; `home` serves the `index` trunk, where the slot is always empty. |
