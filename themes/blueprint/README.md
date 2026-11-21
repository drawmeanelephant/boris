# Blueprint

**A documentation theme for Boris in the Bootstrap 6 token grammar:
CSS-first tokens, `.theme-*` surfaces, `light-dark()`. No Sass, no client
framework, no vendored bytes.**

Blueprint is the shell a project's docs site needs:

- a sticky header with the brand and the built-in Boris search client
  (press `/` to focus it)
- a left sidebar from `{{nav}}` that marks the current page and its section
- a centered prose column with a 72-character measure
- a right-rail outline from `{{toc}}` that becomes a collapsible "On this
  page" bar above the article on narrower screens
- breadcrumbs, tag chips, a status pill and draft/archived banners from
  `{{page-status}}`, an "Up to" parent link, and "See also" link cards from
  `{{relations}}` and `{{backlinks}}`
- a mobile nav drawer and an outline toggle that work with CSS alone (a
  checkbox and its label), plus a skip link and a visible focus ring
- styled Aside kinds (`note`, `tip`, `info`, `warning`, `danger`),
  `<Details>`, code blocks that scroll long lines inside the block,
  tables, inline code, and `kbd`
- light and dark from the reader's system, a print stylesheet, and
  `prefers-reduced-motion` support

Provenance: the token grammar and `.theme-*` composition are inspired by
Bootstrap 6.0.0-alpha.1 (MIT). No Bootstrap code, class names, or bytes are
shipped. The vocabulary is Boris-owned.

Browser floor: `light-dark()`, `oklch()`, `color-mix()`, `:has()`, and
`::details-content` mean Chrome/Edge 131+, Firefox 132+, and Safari 18+.
Older engines still get readable content. The `<Details>` open animation
is skipped where `::details-content` is unsupported.

- Layouts: `layouts/main.html` (article pages), `layouts/section.html`
  (pages with children: `{{children}}` as numbered steps), and
  `layouts/home.html` (landing page: full-width content and a
  `{{children}}` deck, with the sidebar in the drawer at every width)
- Stylesheet: [`assets/css/blueprint.css`](assets/css/blueprint.css)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)
- Specimen: the `boris init --type blueprint` tree, a ten-page docs site

## Selecting it

```bash
boris --input content --html-dir dist --theme themes/blueprint \
  --layout-rule default id:index themes/blueprint/layouts/home.html \
  --layout-rule default id:guides themes/blueprint/layouts/section.html
```

A profile does the same with `layout_rules`; the starter's `boris.json`
sends `id:index` to `home.html` and each section id to `section.html`.

## Make it yours

- **Brand.** The header brand, the `<title>` suffix, and `footer.html` say
  "Blueprint". No layout slot carries the profile's `site.title`, so edit
  the three layouts and the footer.
- **Accent.** Change `--accent-h` (a hue angle) in `:root`. The eleven-step
  accent ramp, links, focus ring, current-page highlight, and primary
  surfaces all derive from it.
- **Scale.** The type scale (`--text-*`), spacing scale (`--space-*`, from
  `--spacer`), radii (`--radius-*`, from `--radius`), and elevation
  (`--shadow-1` to `--shadow-3`) are tokens too.

## Author-facing classes

Raw HTML inside Markdown can use the kit. Every tinted class reads
`--theme-*`, so a `.theme-*` class (`primary`, `secondary`, `success`,
`info`, `warning`, `danger`, `contrast`) re-skins it:

| Class | Use |
|---|---|
| `.hero`, `.actions` | Landing-page hero band and its call-to-action row |
| `.btn` | Solid call to action; `.btn.theme-secondary` is the outline variant |
| `.features`, `.feature`, `.feature__icon` | Feature card deck |
| `.card`, `.grid` | Tinted panel and an auto-fit card grid |
| `.badge`, `.chip` | Inline pill |
| `.fg-muted`, `.fg-faint`, `.fg-primary`, `.bg-2`, `.bg-3` | Color utilities |

```html
<div class="hero">

# Build less. Ship sooner.

<p class="actions"><a class="btn" href="getting-started.html">Get started</a></p>

</div>
```

## Search

Search uses the same browser client as the default `boris` theme, inlined
in each layout. It reads `_boris/search/search-index.json`, which the
compiler publishes. It also sets the brand link's page-relative home
address. Without JavaScript, the search panel says so, and the sidebar and
section pages remain the way around the site.
