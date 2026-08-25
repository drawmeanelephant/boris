### Fixed

- Rendered search no longer indexes shared layout chrome (`<nav>`, `<header>`,
  `<aside>`, `<footer>`) or nested sidebar copy when a page has no declared
  content root, and honors `data-boris-search-ignore` / `data-boris-noindex`
  alongside `data-boris-search-exclude`. Links:
  [the rendered-search contract](/docs/contracts/rendered-search.md),
  [issue 485](https://github.com/drawmeanelephant/boris/issues/485).
