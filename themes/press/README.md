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
