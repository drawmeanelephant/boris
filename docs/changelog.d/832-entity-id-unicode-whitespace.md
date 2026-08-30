### Fixed

- Entity ids now reject Unicode whitespace, not just ASCII space: page
  filenames and `id:`/`parent:` frontmatter values containing `Zs` separators
  (NBSP, ideographic space, hair space, …) or the remaining White_Space code
  points fail validation instead of publishing raw non-ASCII whitespace in
  filenames and hrefs, honoring the identity contract's no-whitespace rule for
  the full Unicode subset while valid UTF-8 ids such as `café` and `日本語`
  keep working. Links:
  [the identity-and-paths contract](/docs/contracts/identity-and-paths.md),
  [#830](https://github.com/drawmeanelephant/boris/issues/830).
