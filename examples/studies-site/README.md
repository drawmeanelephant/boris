# Studies sample site

One specimen corpus for the six thickened framework-inspired themes.
Swap `--theme` to compare them. The CSS is original; the names do not
claim those projects.

```bash
THEME=semantic   # or columns, service, engineering, civic, tokens

./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/$THEME \
  --layout-rule default id:index themes/$THEME/layouts/home.html \
  --layout-rule default role:trunk themes/$THEME/layouts/section.html \
  --html-dir test-output/$THEME \
  --quiet
```
