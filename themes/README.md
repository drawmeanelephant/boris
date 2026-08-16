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

| Theme | Voice | Select it with |
|---|---|---|
| [`boris`](boris/) | Default product chrome. A little strange on purpose. | `--theme themes/boris` (also the product default) |
| [`reference`](reference/) | Calm accessibility-forward documentation | `--theme themes/reference` |
| [`press`](press/) | Editorial paper, crimson masthead, serif reading | `--theme themes/press` |
| [`showcase`](showcase/) | Soft docs + blog shell | `--theme themes/showcase` |
| [`archive`](archive/) | Ordered long-lived field notes | `--theme themes/archive` |

Sample sites that build these themes live under `examples/<name>-site/`.

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

One extra theme for reading that is not US-docs English is welcome later: system CJK stacks, `:lang(ja)` / `:lang(zh)` / `:lang(ko)`, no costume chrome. It is not required for this catalog.

## Related

- Contract: [`docs/contracts/templating-and-themes.md`](../docs/contracts/templating-and-themes.md)
- Author guide: [`content/guides/themes-and-layouts.md`](../content/guides/themes-and-layouts.md)
- Catalog issue: [#574](https://github.com/drawmeanelephant/boris/issues/574)
