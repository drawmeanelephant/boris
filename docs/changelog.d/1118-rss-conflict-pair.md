### Fixed

- `--rss`/`--rss-path` combined with one forbidden companion now names the
  pair as typed (e.g. `error: --rss conflicts with --html-layout`), and a
  missing default `themes/boris/layouts/main.html` on archetype sites
  remediates with the `--html-layout PATH` escape hatch. Links:
  [CLI contract](/docs/contracts/cli.md),
  [layout precedence](/docs/contracts/templating-and-themes.md),
  [issue #1113](https://github.com/drawmeanelephant/boris/issues/1113).
