# Studies sample site

One specimen corpus for eight docs-shell themes: `semantic`, `columns`,
`service`, `engineering`, `civic`, `tokens`, `corporate`, and `minimal`.
Swap `--theme` to compare them. The CSS is original; the names do not
claim the projects that inspired them.

This shared corpus is each theme's specimen. All eight style the same page
shape: a docs graph with a home page, two section trunks, and reference
satellites. One corpus makes them directly comparable, and eight copies of
the same Markdown would drift apart. The corpus exercises what those themes
are expected to style:

- Aside (`note`, `tip`, `info`, `warning`) and native Details
- tables, a footnote, code, and blockquotes
- a page-local image under `index.assets/` and `guides/components.assets/`
- `{{metadata}}` with status and tags
- one typed `relates_to` edge, so `guides/components` renders
  `{{relations}}` and `reference/slots-and-rules` renders `{{backlinks}}`
- breadcrumbs, children, and outlines at three depths

The six themes with named layouts select `home.html` for the index and
`section.html` for the trunks:

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

`corporate` and `minimal` are single-layout themes. Do not pass layout
rules for them, because their `home.html` / `section.html` do not exist and
the build fails with `FileNotFound`:

```bash
THEME=corporate   # or minimal

./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/$THEME \
  --html-dir test-output/$THEME \
  --quiet
```
