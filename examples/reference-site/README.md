# Reference sample site

Specimen Markdown for the shipped [`themes/reference`](../../themes/reference/)
theme. This directory is an example of *using* a first-class theme.

```bash
./zig-out/bin/boris \
  --input examples/reference-site/content \
  --theme themes/reference \
  --layout-rule default id:index themes/reference/layouts/home.html \
  --layout-rule default role:trunk themes/reference/layouts/section.html \
  --html-dir test-output/reference \
  --quiet
```

Keep generated output under ignored `test-output/`.
