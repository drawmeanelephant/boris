### Added

- Every single-layout theme now has a recorded named-layout decision in its
  README ([theme catalog](/themes/README.md), #1050). `journal` gains
  `layouts/archive.html`, a log index whose `$ ls entries/` listing is the
  page's `{{children}}`, for dated-entry trees such as the `changelog`
  starter (`id:changes`). `cards` gains `layouts/home.html`, an intro card
  above a deck of child cards, the shape a cookbook recipe box wants.
  `boris`, `cozy`, `ledger`, `reading`, `corporate`, `minimal`, and
  `html4-strict` stay single shape by design, and each README records the
  reason. `showcase/layouts/home.html` now renders `{{children}}` as a
  search-excluded project grid, so the `portfolio` index lists its projects
  from the graph (#1053). Every catalog theme maps to a buildable specimen in
  [`examples/README.md`](/examples/README.md): `studies-site` is the shared
  corpus for `semantic`, `columns`, `service`, `engineering`, `civic`,
  `tokens`, `corporate`, `minimal`, `boris`, and `html4-strict`, and it gains
  a typed relation and a footnote. Its documented command no longer fails
  with `FileNotFound` for the single-layout themes. `corporate`'s print pass
  also forces a white shell surface and keeps body links underlined.
