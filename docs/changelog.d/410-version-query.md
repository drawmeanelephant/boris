### Added

- `boris --version` / `boris -V` now print the compiler id (e.g.
  `boris/0.8.1`) to stdout and exit 0, short-circuiting like `--help` (no
  content tree is read), and are listed in the
  [README quickstart](/README.md). Closes the version-query gap for tooling
  that needs to pin the compiler.
