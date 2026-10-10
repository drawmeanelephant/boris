# Cards

Soft cards and quiet docs. Hand-authored. Not DaisyUI.

- Layouts: `main.html`, `home.html`
- Assets: `assets/css/cards.css` (system stack)
- Sample site: [`examples/cards-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/cards-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/cards-site/content \
  --theme themes/cards \
  --layout-rule default id:index themes/cards/layouts/home.html \
  --html-dir test-output/cards \
  --quiet
```

## Named layouts

- `main.html` is the reading card for every page, with the nav and outline
  rails.
- `home.html` is the index of a collection. The intro card (metadata, prose,
  and the outline folded into its foot) sits above a deck of `{{children}}`,
  one card per direct satellite, under "In this collection". There is no
  outline rail, so the deck gets the width. It is the shape a recipe box
  wants: `boris init --type cookbook` content builds with
  `--cooklang --layout-rule default id:index themes/cards/layouts/home.html`
  and shows each recipe as a card. Both layouts carry the same slots,
  search exclusions, and skip target.

`section`, `blog`, `archive`, and `print` are declined. A soft-card docs
site has one middle level, and `main.html` already lists it under
"In this section". Cards is not a dated-entry voice, and `@media print`
drops the rails and card chrome from either layout.

## Slot coverage

`{{relations}}` and `{{backlinks}}` render as two soft cards under "In this
section", labelled "Related" and "Linked from", with the relation kind as a
pill. Both emit nothing on a page without semantic relations.

Intentionally absent:

- `{{tags}}` — `{{metadata}}` already shows Tags in the tinted strip at the
  top of the card. A second chip list would repeat it.
- `{{parent}}` — `{{breadcrumb}}` in the top bar already links the parent.
- `{{page-status}}` — `{{metadata}}` prints Status as text. The theme's quiet
  voice does not add a separate draft stamp.
