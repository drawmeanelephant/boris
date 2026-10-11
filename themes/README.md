# Shipped themes

First-class themes live here. `examples/` holds sample sites and unfinished
studies that consume a theme — it is not a second theme attic.

A theme is trusted static HTML plus copied bytes. Boris never fetches.

```text
themes/<name>/
  README.md
  layouts/main.html      # required fallback
  layouts/*.html         # optional named shapes
  footer.html            # when layouts use {{footer}}
  assets/                # CSS, optional local images or fonts
  licenses/              # only when a third-party file is actually shipped
```

## Catalog

| Theme | Voice | Layouts | Select it with |
|---|---|---|---|
| [`boris`](boris/) | Default product chrome: orange accent, sticky rail, slightly-too-large type. A little strange on purpose. | `main` (single shape by design) | `--theme themes/boris` (also the product default) |
| [`reference`](reference/) | Calm accessibility-forward documentation | `main`, `home`, `section` | `--theme themes/reference` |
| [`press`](press/) | Editorial paper, crimson masthead, serif reading | `main`, `home`, `section`, `blog`, `archive` | `--theme themes/press` |
| [`showcase`](showcase/) | Soft docs + blog shell: cards, pill badges, kind-tinted callouts | `main`, `home`, `section`, `blog` | `--theme themes/showcase` |
| [`archive`](archive/) | Ordered long-lived field notes: paper slips, ledger rules, numbered plates | `main`, `archive` | `--theme themes/archive` |
| [`field-notes`](field-notes/) | Restrained blue notes | `main`, `home`, `section` | `--theme themes/field-notes` |
| [`compact`](compact/) | Small-type documentation | `main`, `home` | `--theme themes/compact` |
| [`cards`](cards/) | Soft cards and quiet docs | `main`, `home` | `--theme themes/cards` |
| [`cozy`](cozy/) | Mid-2000s personal blog | `main` (single shape by design) | `--theme themes/cozy` |
| [`journal`](journal/) | Phosphor terminal diary | `main`, `archive` | `--theme themes/journal` |
| [`ledger`](ledger/) | Dense early-web nodes | `main` (single shape by design) | `--theme themes/ledger` |
| [`reading`](reading/) | Ink-only typesetting for text that is not US-docs English | `main` (single shape by design) | `--theme themes/reading` |
| [`semantic`](semantic/) | HTML-first, class-light docs | `main`, `home`, `section` | `--theme themes/semantic` |
| [`columns`](columns/) | Broadsheet: masthead, datelines, prose set in real columns | `main`, `home`, `section` | `--theme themes/columns` |
| [`service`](service/) | Public-service information | `main`, `home`, `section` | `--theme themes/service` |
| [`engineering`](engineering/) | Dense engineering docs | `main`, `home`, `section` | `--theme themes/engineering` |
| [`civic`](civic/) | Public-information shell: banner, gold rule, tinted alerts | `main`, `home`, `section` | `--theme themes/civic` |
| [`tokens`](tokens/) | Fluid custom properties: every size, step, and kind colour is a token | `main`, `home`, `section` | `--theme themes/tokens` |
| [`corporate`](corporate/) | Dense product-docs chrome | `main` (single shape by design; `@media print` is the CV shape) | `--theme themes/corporate` |
| [`minimal`](minimal/) | Corporate's shell, flat and square, no search | `main` (single shape by design) | `--theme themes/minimal` |
| [`lab`](lab/) | Dark-first lab terminal, three color modes, prints on paper from any mode | `main`, `print` | `--theme themes/lab` |
| [`gallery`](gallery/) | Image-first wall, album grid, museum-label captions | `main`, `home` | `--theme themes/gallery` (`id:index` → `layouts/home.html`) |
| [`html4-strict`](html4-strict/) | Opt-in legacy HTML 4.01 Strict compatibility | `main` (single shape by design) | `--theme themes/html4-strict --target-profile default=html4-strict` |

Named layouts are selected with `--layout-rule` or a profile's
`layout_rules`, never from frontmatter. Each theme README gives the exact
rules and, for a single-layout theme, why it declines more shapes.

Every theme has a buildable specimen. The table in
[`examples/README.md`](../examples/README.md#specimen-for-every-theme)
maps each one to its sample site or shared corpus.

## First-class bar

- Closed slot vocabulary only. See [`templating-and-themes.md`](../docs/contracts/templating-and-themes.md).
- Style Aside, Details, tables, definition lists, footnotes, code, blockquotes, content-local images, metadata, and children. Include `{{relations}}` / `{{backlinks}}` when the page shape can use them.
- Skip link, visible `:focus-visible`, readable narrow stacking, `prefers-reduced-motion`, print pass.
- Search is optional. If present, use the first-party inline consumer and the documented `data-boris-search-*` hooks. No `<script src>`. No vendored JavaScript.
- No fake chrome: no `href="#"`, no dead theme-toggle, no visual-only search.
- Generated HTML and CSS contain no `http(s)://` resource URLs.

## Asset policy

| Kind | Rule |
|---|---|
| Remote URLs | None in published HTML/CSS. |
| Linked or vendored JavaScript | None. The default search UI is first-party inline only. |
| Vendored CSS libraries | Only if the static file is already in that theme. README records name, exact version, license, and where to get the current release. Boris copies the bytes; it does not run the library's toolchain. |
| Fonts | Prefer a system stack. If a theme needs a specific face, ship the files under `assets/fonts/` with the license. Do not name a webfont that is not shipped. Do not author original font files. |
| Inspiration | A one-line provenance note is fine. The directory name must be Boris-owned. |

No theme in this catalog currently ships a font file or a third-party CSS library. That is intentional.

## Stretch

[`reading`](reading/) is the one non-US-docs typesetting theme: system CJK
stacks and `:lang(ja)` / `:lang(zh)` / `:lang(ko)`. It is not a costume set
and it does not vendor webfonts.

## Related

- Contract: [`docs/contracts/templating-and-themes.md`](../docs/contracts/templating-and-themes.md)
- Author guide: [`content/guides/themes-and-layouts.md`](../content/guides/themes-and-layouts.md)
- Catalog issue: [#574](https://github.com/drawmeanelephant/boris/issues/574)
