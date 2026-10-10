# Journal sample site

Specimen for [`themes/journal`](../../themes/journal/). The `index` page is
the log, so it renders through the named `archive.html` layout; every entry
falls back to `main.html`.

```bash
./zig-out/bin/boris \
  --input examples/journal-site/content \
  --theme themes/journal \
  --layout-rule default id:index themes/journal/layouts/archive.html \
  --html-dir test-output/journal \
  --quiet
```
