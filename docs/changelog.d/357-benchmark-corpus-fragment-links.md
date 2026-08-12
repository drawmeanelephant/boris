### Added

- The benchmark corpus generator now supports `--fragment-links N` to emit
  deterministic `[[entity#overview]]` wiki fragment links on every generated
  page, so heading-harvest and its follow-on performance work can be measured
  without post-processing; fragment targets follow the [heading ids
  contract](/docs/contracts/heading-ids.md).
