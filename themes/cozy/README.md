# Cozy

Mid-2000s personal blog. Graph nav is real. There is no fake blogroll.

- Layouts: `main.html`
- Assets: `assets/cozy.css` (Georgia / Verdana system stack)
- Sample site: [`examples/cozy-site/`](../../examples/cozy-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/cozy-site/content \
  --theme themes/cozy \
  --html-dir test-output/cozy \
  --quiet
```

## Slot coverage

- `{{relations}}` renders as "Related entries" and `{{backlinks}}` as
  "TrackBacks" under the entry footer, with the relation kind in
  parentheses. Both emit nothing on a page without semantic relations.
- `{{page-status}}` is a class token on the entry (`entry--draft`,
  `entry--archived`). A draft gets a dashed "Draft — not yet published"
  stamp; an archived entry gets "From the archives". The Status line in
  `{{metadata}}` still carries the same word as text.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already prints Tags in the entry header, the
  way a 2000s blog showed "Filed under". A chip list would repeat it.
- `{{parent}}` — the breadcrumb directly above the entry already links the
  parent.
