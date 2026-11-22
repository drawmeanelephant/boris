### Added

- The Boris GitHub Pages site now publishes `robots.txt` (pointing at
  `sitemap.xml`), a custom `404.html`, and a 1200×630 social card from a root
  `static/` passthrough directory, and every page carries compiler-owned
  canonical, Open Graph, and Twitter card metadata. The workflow builds with
  `boris build --profile`. Links:
  [the GitHub Pages guide](/docs/github-pages.md),
  [the head-metadata contract](/docs/contracts/head-metadata.md),
  [#1189](https://github.com/drawmeanelephant/boris/issues/1189).

### Fixed

- `boris-github-pages-audit` accepts publication-plan schemas 2 and 3, so
  `audit_deployment` still runs when the Pages profile declares `head`
  metadata. Link:
  [the deployment-evidence contract](/docs/contracts/github-pages-deployment-evidence.md).
