### Changed

- Pared `boris init --type` down from sixteen archetypes to six core shapes
  (`docs`, `garden`, `cookbook`, `blog`, `textile`, `photo-gallery`) so
  `init` covers each distinct compiler mode and seam without doubling as a
  shadow theme catalog; all 24 themes remain shipped under
  [`themes/`](/themes/README.md). Enriched `blog` with a `status: draft`
  post and a profile declaring `site.url` + `head` + `rss` (`feed.xml`) +
  `sitemap` (`sitemap.xml`) so the canonical feed/draft recipe stays
  available out of the box. Links:
  [CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification),
  [init theme matrix](/docs/init-theme-matrix.md).
