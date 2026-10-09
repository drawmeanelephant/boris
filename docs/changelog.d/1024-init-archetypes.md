### Added

- `boris init [DIR] [--type NAME]` materializes five deterministic,
  compile-verified starter archetypes: `docs` (the unchanged default),
  `garden` (dense wiki links, semantic relations, `{{include}}`
  composition, and a registered `<Aside>` under the `ledger` theme),
  `cookbook` (Cooklang `.cook` pages under `cards`, profile declaring
  `"input_format": "cook"`), `blog` (dated posts on a parent chain under
  `cozy`), and `textile` (`.textile` pages under `press`, profile
  declaring `"input_format": "textile"`). Each archetype ships its own
  theme byte-identical to the `themes/` catalog and a `boris.json`
  profile that drives the build — the compiler gains no per-archetype
  branches. Missing-content diagnostics now point at `boris init` as a
  starter path. See [the CLI contract](/docs/contracts/cli.md#init-deterministic-starter-scaffold-with-self-verification),
  [the includes contract](/docs/contracts/includes-and-wiki-links.md),
  [Cooklang compatibility](/docs/contracts/cooklang-compatibility.md), and
  [Textile compatibility](/docs/contracts/textile-compatibility.md).
