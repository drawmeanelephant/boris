# Engineering

Dense engineering documentation. Inspired by Primer's boxes and labels;
the CSS is original. Not Primer.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Shared specimen: [`examples/studies-site/`](../../examples/studies-site/)

```bash
./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/engineering \
  --layout-rule default id:index themes/engineering/layouts/home.html \
  --layout-rule default role:trunk themes/engineering/layouts/section.html \
  --html-dir test-output/engineering \
  --quiet
```
