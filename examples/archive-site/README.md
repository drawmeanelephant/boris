# Archive sample site

Specimen Markdown for the shipped [`themes/archive`](../../themes/archive/)
theme.

```bash
./zig-out/bin/boris \
  --input examples/archive-site/content \
  --theme themes/archive \
  --layout-rule default id:archive themes/archive/layouts/archive.html \
  --html-dir test-output/archive \
  --quiet
```
