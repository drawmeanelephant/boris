### Added

- Added opt-in `--timings` phase/counter reporting and a deterministic
  ReleaseFast benchmark corpus with a CI regression gate; see the
  [benchmark guide](/tools/testdata-generator/README.md).
- Hardened benchmark corpus cleanup to reject output paths that pass through
  existing symlink components before deleting anything.
- Anchored recursive cleanup to no-follow parent directory handles so a path
  component swap cannot redirect deletion outside the output tree.
