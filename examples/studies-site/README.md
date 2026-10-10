# Studies sample site

One specimen corpus for eight docs-shell themes: `semantic`, `columns`,
`service`, `engineering`, `civic`, `tokens`, `corporate`, and `minimal`.
Swap `--theme` to compare them. The CSS is original; the names do not
claim the projects that inspired them. The same corpus also builds under
`boris` and `html4-strict` ([below](#also-built-from-this-corpus)).

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

`corporate`, `minimal`, and `boris` are single-layout themes. Do not pass
layout rules for them, because their `home.html` / `section.html` do not
exist and the build fails with `FileNotFound`:

```bash
THEME=corporate   # or minimal, boris

./zig-out/bin/boris \
  --input examples/studies-site/content \
  --theme themes/$THEME \
  --html-dir test-output/$THEME \
  --quiet
```

## Also built from this corpus

- [`boris`](../../themes/boris/), the product default, builds this corpus
  with the single-layout command above. Its larger dogfood specimen is the
  repository's own [`content/`](../../content/) docs site
  (`./zig-out/bin/boris --theme themes/boris --html-dir test-output/boris-docs --quiet`
  from the repository root).
- [`html4-strict`](../../themes/html4-strict/) builds the same corpus under
  the Strict profile. That lets you compare it with the HTML5 shells above.
  Every assembled page passes the Strict check, Details render expanded, and
  the search UI is absent by design:

  ```bash
  ./zig-out/bin/boris \
    --input examples/studies-site/content \
    --theme themes/html4-strict \
    --target-profile default=html4-strict \
    --html-dir test-output/html4-strict \
    --quiet
  ```

  The shared URL check in [`examples/README.md`](../README.md) prints one
  line per page for this build: the `http://www.w3.org/TR/html4/strict.dtd`
  system identifier in the Strict DOCTYPE. The profile requires that line.
  It is not a fetched resource.
