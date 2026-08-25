# Showcase sample site

Specimen Markdown for the shipped [`themes/showcase`](../../themes/showcase/)
theme (docs + blog).

```bash
./zig-out/bin/boris \
  --input examples/showcase-site/content \
  --theme themes/showcase \
  --layout-rule default id:index themes/showcase/layouts/home.html \
  --layout-rule default 'glob:blog/*' themes/showcase/layouts/blog.html \
  --layout-rule default role:trunk themes/showcase/layouts/section.html \
  --html-dir test-output/showcase \
  --quiet
```
