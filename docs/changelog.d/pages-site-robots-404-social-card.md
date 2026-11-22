### Added

- The Boris GitHub Pages site now publishes `robots.txt` (pointing at
  `sitemap.xml`), a custom `404.html`, and a 1200×630 social card from a root
  `static/` passthrough directory, and every page carries compiler-owned
  canonical, Open Graph, and Twitter card metadata. The workflow builds with
  `boris build --profile`. Links:
  [the GitHub Pages guide](/docs/github-pages.md),
  [the head-metadata contract](/docs/contracts/head-metadata.md),
  [#1189](https://github.com/drawmeanelephant/boris/issues/1189).
