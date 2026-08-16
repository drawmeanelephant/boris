### Changed

- Frontmatter accepts the closed Cooklang `servings` count (`serves` / `yield`
  are aliases). `boris recipe-scale --servings N` scales by
  `N / current` (missing current is 1). Every other Cooklang metadata name
  stays `EFRONTMATTER`
  ([#598](https://github.com/drawmeanelephant/boris/issues/598),
  [frontmatter](/docs/contracts/frontmatter.md),
  [Cooklang](/docs/contracts/cooklang-compatibility.md)).
