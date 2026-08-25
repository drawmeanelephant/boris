# Tokens

Fluid custom properties. Inspired by Open Props; the CSS is original.
Not Open Props. System font stack only.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/tokens \
  --layout-rule default id:index themes/tokens/layouts/home.html \
  --layout-rule default role:trunk themes/tokens/layouts/section.html \
  --html-dir test-output/tokens \
  --quiet
```
