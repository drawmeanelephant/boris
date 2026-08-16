# Field Notes sample site

```bash
./zig-out/bin/boris \
  --input examples/field-notes-site/content \
  --theme themes/field-notes \
  --layout-rule default id:index themes/field-notes/layouts/home.html \
  --layout-rule default role:trunk themes/field-notes/layouts/section.html \
  --html-dir test-output/field-notes \
  --quiet
```
