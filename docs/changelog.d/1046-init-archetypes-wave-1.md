### Added

- [The init theme coverage matrix](/docs/init-theme-matrix.md) names at
  least two smoke-verified first-party themes for every `boris init --type`
  scenario, the theme slots each one carries, and the theme gaps that
  remain ([#1051](https://github.com/drawmeanelephant/boris/issues/1051)).
- `boris init --type landing` writes a single-Trunk site under `service`:
  one long page composed from `{{include}}` section fragments, one
  satellite, and profile `layout_rules` that send `id:index` to the
  theme's `home.html`
  ([#1054](https://github.com/drawmeanelephant/boris/issues/1054),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification)).
- `boris init --type wiki` writes a three-level reference tree under
  `reference` (index → section hubs → entries) with cross-entry wiki
  links; `layout_rules` send the index to `home.html` and the hubs, via a
  single `glob:wiki/*` rule, to `section.html`
  ([#1055](https://github.com/drawmeanelephant/boris/issues/1055)).
- `boris init --type link-in-bio` writes the smallest starter: one trunk
  page holding a personal link list, under `minimal`
  ([#1057](https://github.com/drawmeanelephant/boris/issues/1057)).
- `boris init --type changelog` writes release notes under `journal`: an
  `index` → `changes` → dated-entry chain with `published_at` +
  `summary`, and one `status: draft` unreleased entry that renders but
  stays out of search, RSS, and sitemap output
  ([#1056](https://github.com/drawmeanelephant/boris/issues/1056),
  [status gating](/docs/contracts/html-output.md)).
- `boris init --type resume` writes a single-page CV under `corporate`:
  tags rendered by `{{metadata}}`, one "now" satellite, and the theme's
  print stylesheet as the PDF path
  ([#1058](https://github.com/drawmeanelephant/boris/issues/1058)).
- `boris init --type newsletter` writes a weekly paper under `press`
  whose `layout_rules` route the masthead, back-issue archive, and dated
  issues to press's `home`, `archive`, and `blog` layouts. Its profile
  declares `site.url` and a target `sitemap`, so the first build emits
  `dist/sitemap.xml`. Profile `rss` is not declared yet because press
  layouts lack the `{{head}}` slot the RSS rider requires
  ([#1060](https://github.com/drawmeanelephant/boris/issues/1060),
  [head metadata](/docs/contracts/head-metadata.md#bounded-rss-rider-and-execution-boundary)).
