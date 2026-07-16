<!--
Filename: 89-astro-archaeology-p1.md
Migration-lab tooling only; not a product compiler change.
-->

### Fixed

- Astro migration archaeology discovers content under root-level `content/` as
  well as `src/content/`, and classifies site-root absolute hrefs (`/`,
  `/about`) as routes instead of blind `public/` assets so missing pages report
  as broken internal links.
  See [tools/migration-lab/README.md](/tools/migration-lab/README.md).
