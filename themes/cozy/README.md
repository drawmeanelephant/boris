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

## Named layouts

Single shape by design. A mid-2000s personal blog has one page shape: the
entry column beside the sidebar. The front page is an entry too. Its
"Recent posts" panel is `{{children}}`, so a blog index lists its posts
without a separate `home`, `blog`, or `archive` layout. That includes the
`blog` starter tree. `section` has no meaning in a flat blog, and
`@media print` already drops the sidebar for paper.

## Slot coverage

- `{{relations}}` renders as "Related entries" and `{{backlinks}}` as
  "TrackBacks" under the entry, with the relation kind in
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
