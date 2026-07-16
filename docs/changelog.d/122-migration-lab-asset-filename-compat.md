### Added

- Migration-lab **asset-filename** mode sanitizes content-local asset names
  (spaces, Unicode, `%20`) into Boris-safe ASCII paths, rewrites Markdown
  references, and records original/destination/SHA-256 without relaxing core
  asset validation; see
  [migration-lab README](/tools/migration-lab/README.md) and
  [hostile-asset-filenames](/tools/migration-lab/fixtures/hostile-asset-filenames/).
