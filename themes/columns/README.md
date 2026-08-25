# Columns

Boxed, CSS-only documentation. Inspired by Bulma's component vocabulary;
the CSS is original. Not Bulma.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/columns \
  --layout-rule default id:index themes/columns/layouts/home.html \
  --layout-rule default role:trunk themes/columns/layouts/section.html \
  --html-dir test-output/columns \
  --quiet
```
