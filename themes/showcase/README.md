# Showcase

Docs + blog shell with a soft component feel. Hand-authored CSS. DaisyUI
was evaluated and rejected; this sheet is not DaisyUI and must not be
labeled as such.

- Layouts: `home`, `section`, `blog`, `main`
- Assets: local CSS and mark SVG. System UI stack.
- Sample site: [`examples/showcase-site/`](../../examples/showcase-site/)

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
