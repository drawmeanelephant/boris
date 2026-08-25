# Auxiliary tools accept --version/-V

## Added

- Every standalone binary now answers `--version`/`-V` with a single
  `<tool>/<release>` id line on stdout and exit 0, mirroring the main
  compiler's `--version` contract
  ([#787](https://github.com/drawmeanelephant/boris/issues/787)):
  `boris-package`, `boris-source-rag`, `boris-content-audit`,
  `boris-search-index`, `boris-docs-maintenance`, `boris-migration-lab`,
  `boris-testdata`, and `boris-github-pages-audit`. Previously each printed a
  different unknown-flag error (or a bare usage dump with exit 1), so kit
  consumers had no uniform version probe; two of the three binaries shipped in
  agent kits were affected. Help text lists the new flag, and the flag wins
  position-independently over malformed option values where the tool already
  gave `--help` that precedence.
