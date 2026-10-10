# Cards sample site

Specimen for [`themes/cards`](../../themes/cards/). The `index` page renders
through the named `home.html` layout as a deck of child cards; every other
page falls back to `main.html`.

```bash
./zig-out/bin/boris \
  --input examples/cards-site/content \
  --theme themes/cards \
  --layout-rule default id:index themes/cards/layouts/home.html \
  --html-dir test-output/cards \
  --quiet
```
