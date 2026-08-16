# Field Notes

Restrained blue field notes. Inspired by Pure.css's small footprint; this
sheet is original and is not Pure.css.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Assets: `assets/field-notes.css` (system stack)
- Sample site: [`examples/field-notes-site/`](../../examples/field-notes-site/)

```bash
./zig-out/bin/boris \
  --input examples/field-notes-site/content \
  --theme themes/field-notes \
  --layout-rule default id:index themes/field-notes/layouts/home.html \
  --layout-rule default role:trunk themes/field-notes/layouts/section.html \
  --html-dir test-output/field-notes \
  --quiet
```
