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
