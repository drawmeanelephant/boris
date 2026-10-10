### Changed

- `boris init` starters use the named layouts that
  [#1050](https://github.com/drawmeanelephant/boris/issues/1050) added.
  The `cookbook` profile sends `id:index` to the `cards` theme's `home.html`,
  which shows each recipe as a card. The rule selects the `.cook` index
  like any other page. The `changelog` profile sends `id:changes` to the
  `journal` theme's `archive.html`, whose listing names the published
  releases and leaves out the draft. The `portfolio` index drops its
  hand-written project list, because the `showcase` home now lists the
  about page and the projects through `{{children}}`
  ([#1053](https://github.com/drawmeanelephant/boris/issues/1053)). Both new
  layout files are embedded too, so every starter theme again matches its
  catalog copy file for file
  ([#1046](https://github.com/drawmeanelephant/boris/issues/1046),
  [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification),
  [theme matrix](/docs/init-theme-matrix.md)).
