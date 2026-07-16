### Added

- Bounded Notion “Markdown & CSV” export migration mode under
  [`tools/migration-lab/`](tools/migration-lab/) (`--mode=notion` /
  `--export`): deterministic page discovery, nested path→entity-id mapping,
  unambiguous local link and attachment rewrite, media inventory/manifest, and
  human-review reports for databases/CSV, relation/rollup, synced blocks,
  embeds, unsupported blocks, and ambiguous/unresolved targets — with a public
  synthetic fixture and no product-compiler coupling. See
  [migration-lab README](tools/migration-lab/README.md).
