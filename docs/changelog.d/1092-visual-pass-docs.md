### Changed

- Visual quality pass for the docs-voice themes (#1049, part of #1045):
  [`reference`](/themes/reference/README.md), [`compact`](/themes/compact/README.md),
  [`semantic`](/themes/semantic/README.md), [`columns`](/themes/columns/README.md),
  [`service`](/themes/service/README.md), [`engineering`](/themes/engineering/README.md),
  [`civic`](/themes/civic/README.md), and [`tokens`](/themes/tokens/README.md)
  now style breadcrumbs, outlines, Details, definition lists, footnotes,
  figures, h4, and per-kind Aside colours in each theme's voice, and keep
  Markdown table alignment. These constructs previously fell back to browser
  defaults. Dark-mode links in `semantic`, `civic`, and `tokens` now pass
  contrast (they measured 2.4–3.6:1). The six themes whose layouts show
  `<h1>{{title}}</h1>` mark it with `data-boris-search-title`, so a page with
  no authored heading is indexed under its own title rather than the theme
  name ([rendered search](/docs/contracts/rendered-search.md)). They also
  drop `aria-label`s that sat on role-less wrapper `div`s. Measured contrast
  is in each theme's `ACCESSIBILITY.md`.
