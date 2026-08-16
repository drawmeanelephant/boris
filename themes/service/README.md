# Service

Public-service information design. Inspired by GOV.UK's restraint; the
CSS is original. Not GOV.UK Frontend.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/service \
  --layout-rule default id:index themes/service/layouts/home.html \
  --layout-rule default role:trunk themes/service/layouts/section.html \
  --html-dir test-output/service \
  --quiet
```
