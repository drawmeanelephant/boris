### Added

- `boris --profile PATH` on the HTML build emits Standard.site verification
  surfaces (head links + well-known) when the profile target is
  `standard-site`. `standard-site verify` can now pass against a CLI-built
  `dist/`. See the [Standard.site contract](/docs/contracts/standard-site.md)
  and [#533](https://github.com/drawmeanelephant/boris/issues/533).
