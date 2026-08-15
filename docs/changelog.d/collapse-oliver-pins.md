<!--
Filename: collapse-oliver-pins.md
Category: Changed
-->

### Changed

- Collapsed Boris's two Oliver dependencies into one: the Markdown renderer
  extensions and the Cooklang stack now share a single `.oliver` pin at Oliver
  `main` `c0b3d2b` (oliver#39 merged, embargo lifted). The `.oliver_cooklang`
  split dependency (previously `bcf167fa`) is deleted; `cooklang_seam.zig`
  imports the shared module as `oliver`. The Cooklang seam therefore also
  absorbs the oliver#55/#56 audit fixes (scaling div-by-zero guard, NUL → U+FFFD
  in the HTML renderer). Pin table:
  [oliver-renderer.md](/docs/contracts/oliver-renderer.md).
