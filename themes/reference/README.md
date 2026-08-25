# Reference

Accessibility-forward documentation theme. Skip link, named landmarks,
visible focus, dark system preference, reduced motion, print.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Assets: local CSS and mark SVG. System Palatino/Georgia serif + UI sans.
- Sample site: [`examples/reference-site/`](../../examples/reference-site/)

```bash
./zig-out/bin/boris \
  --input examples/reference-site/content \
  --theme themes/reference \
  --layout-rule default id:index themes/reference/layouts/home.html \
  --layout-rule default role:trunk themes/reference/layouts/section.html \
  --html-dir test-output/reference \
  --quiet
```
