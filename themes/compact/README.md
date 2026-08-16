# Compact

Small-type documentation. Inspired by Chota's scale; this sheet is original
and is not Chota.

- Layouts: `home.html` (`id:index`), `main.html`
- Assets: `assets/css/compact.css` (system stack)
- Sample site: [`examples/compact-site/`](../../examples/compact-site/)

```bash
./zig-out/bin/boris \
  --input examples/compact-site/content \
  --theme themes/compact \
  --layout-rule default id:index themes/compact/layouts/home.html \
  --html-dir test-output/compact \
  --quiet
```
