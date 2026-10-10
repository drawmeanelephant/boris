### Fixed

- Themes visual pass, product batch (#1049): `boris`, `showcase`,
  `archive`, `lab`, `html4-strict`, `corporate`, `minimal`, and `gallery`
  now style every authored construct (all five Aside kinds with measured
  kind colours, Details, aligned tables, nested and definition lists,
  footnotes, code, blockquotes, figures, h1–h4, children). Fixes include
  table column alignment overridden by `text-align` in `boris`, `showcase`,
  `lab`, and `gallery`, Aside
  titles that `corporate` and `minimal` never matched (`admonition__title`),
  images and code overflowing at 390px in `showcase` and `archive`, `lab`
  printing near-white headings from its dark and pride modes, `archive`
  showing an empty "More entries" panel, and the `archive` index taking the
  theme name as its search title (its layout `<h1>` now carries
  `data-boris-search-title`). The `corporate` CV print is unchanged. See
  [the theme catalog](/themes/README.md) and
  [the rendered-search contract](/docs/contracts/rendered-search.md).
