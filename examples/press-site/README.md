# Press sample site

Specimen Markdown for the shipped [`themes/press`](../../themes/press/) theme.

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

`published-pages.txt` is a live-page list for the standalone search indexer
when a probe directory also contains compiler proof artifacts.
