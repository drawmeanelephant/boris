# Semantic

HTML-first documentation. Inspired by Pico's class-light approach; the
CSS is original.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/semantic \
  --layout-rule default id:index themes/semantic/layouts/home.html \
  --layout-rule default role:trunk themes/semantic/layouts/section.html \
  --html-dir test-output/semantic \
  --quiet
```
