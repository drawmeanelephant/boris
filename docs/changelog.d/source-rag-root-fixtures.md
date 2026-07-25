### Fixed

- `boris-source-rag` now scans the root `fixtures/` tree, which the contracts
  already describe as part of the fixture corpus but the exporter silently
  omitted. Adds 90 files to `--profile=all` and `--profile=tools`.
