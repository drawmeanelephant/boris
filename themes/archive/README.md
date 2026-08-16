# Archive

Ordered long-lived field notes. Direct children are the index; entry pages
use the fallback layout.

- Layouts: `archive.html` (`id:archive`), `main.html`
- Assets: `assets/archive.css`. System Palatino/Georgia serif.
- Sample site: [`examples/archive-site/`](../../examples/archive-site/)

```bash
./zig-out/bin/boris \
  --input examples/archive-site/content \
  --theme themes/archive \
  --layout-rule default id:archive themes/archive/layouts/archive.html \
  --html-dir test-output/archive \
  --quiet
```
