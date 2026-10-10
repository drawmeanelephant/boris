# Cards

Soft cards and quiet docs. Hand-authored. Not DaisyUI.

- Layouts: `main.html`
- Assets: `assets/css/cards.css` (system stack)
- Sample site: [`examples/cards-site/`](../../examples/cards-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

```bash
./zig-out/bin/boris \
  --input examples/cards-site/content \
  --theme themes/cards \
  --html-dir test-output/cards \
  --quiet
```

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
