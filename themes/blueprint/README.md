# Blueprint

**Bootstrap 6's grammar on a Boris shell: CSS-first tokens, `.theme-*`
surfaces, `light-dark()` — no Sass, no JavaScript, no vendored bytes.**

Every visual value is a `:root` custom property (`--bg-*`, `--fg-*`,
`--*-bg-subtle`/`--*-fg`/`--*-border`, `--spacer`, `--radius-*`), and every
tinted component reads `--theme-*` component tokens, so a `.theme-info` or
`.theme-warning` class re-skins it at runtime the way Bootstrap 6's token
maps do at build time. The site graph sits in a left-rail disclosure, the
page outline in a right rail, and `{{children}}` becomes a card deck on
`home.html`. Status is a pill (`draft` warns, `published` confirms,
`archived` mutes); admonitions ride the same `.theme-*` surface system;
`details.details` animates open with the pure-CSS `::details-content`
accordion trick.

Provenance: the token grammar and `.theme-*` composition are inspired by
Bootstrap 6.0.0-alpha.1 (MIT). No Bootstrap code, class names, or bytes are
shipped — this is a Boris-owned vocabulary.

Browser floor follows that inspiration: `light-dark()`, `oklch()`,
`color-mix()`, `::details-content`, and sticky `position` mean Chrome/Edge
130+, Firefox 132+, Safari 18+. Older engines still get readable content;
the rail stays a plain disclosure and colors fall back where supported.

- Layouts: `layouts/main.html`, `layouts/home.html` (hero + `{{children}}` deck)
- Stylesheet: [`assets/css/blueprint.css`](assets/css/blueprint.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: [`examples/studies-site`](../../examples/studies-site/) with the
  home rule below; the `boris init --type blueprint` tree is the teaching
  specimen

## Selecting it

```bash
boris --input content --html-dir dist --theme themes/blueprint
boris --input content --html-dir dist --theme themes/blueprint \
  --layout-rule default id:index themes/blueprint/layouts/home.html
```

## Author-facing classes

Raw HTML inside Markdown can use the kit: `.card`, `.badge`, `.chip`,
`.btn`, `.grid`, `.fg-muted`, `.fg-faint`, `.fg-primary`, `.bg-2`, `.bg-3`,
and the `.theme-*` surfaces (`primary`, `secondary`, `success`, `info`,
`warning`, `danger`, `contrast`). Everything reads `--theme-*`:

```html
<div class="card theme-info">Tinted info card.</div>
<span class="badge theme-warning">beta</span>
<div class="grid"><div class="card">…</div><div class="card">…</div></div>
```

## Retheme it

The whole palette is `:root` token overrides — edit
[`assets/css/blueprint.css`](assets/css/blueprint.css) directly in a copied
theme, or point a downstream `assets/` stylesheet at the same names. There
is no build step; changing `--primary-*` moves every primary surface.
