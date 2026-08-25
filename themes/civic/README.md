# Civic

Public-information shell. Inspired by USWDS tokens and banners; the CSS
is original. Not USWDS. System font stack only.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/civic \
  --layout-rule default id:index themes/civic/layouts/home.html \
  --layout-rule default role:trunk themes/civic/layouts/section.html \
  --html-dir test-output/civic \
  --quiet
```
