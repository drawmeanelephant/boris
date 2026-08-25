### Changed

- The IR `build-report.json` now records compiler identity under `compiler`
  (immediately after `schemaVersion`), identical to `manifest.json`'s value on
  the same run and written on both success and content-failure paths, so a
  tool reading diagnostics can attribute them to the exact compiler that
  produced them. Field names stay per-artifact (`compiler`, `compiler_id`,
  `compilerId`) and are now documented; `graph.json` remains identity-free by
  design. Links: [IR schema](/docs/contracts/ir-schema.md),
  [CLI contract](/docs/contracts/cli.md),
  [#638](https://github.com/drawmeanelephant/boris/issues/638).
