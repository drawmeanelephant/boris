# Cozy

Mid-2000s personal blog. Graph nav is real. There is no fake blogroll.

- Layouts: `main.html`
- Assets: `assets/cozy.css` (Georgia / Verdana system stack)
- Sample site: [`examples/cozy-site/`](../../examples/cozy-site/)

```bash
./zig-out/bin/boris \
  --input examples/cozy-site/content \
  --theme themes/cozy \
  --html-dir test-output/cozy \
  --quiet
```
