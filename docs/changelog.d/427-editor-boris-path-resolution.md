<!--
Filename: 427-editor-boris-path-resolution.md
Keep exactly one category heading.
-->

### Fixed

- `boris-editor` now resolves a path-like `--boris` value against the editor's
  working directory at startup (bare command names still resolve through
  `PATH`), so the documented relative invocation works and bad paths fail fast.
  See [the host README](/editor/README.md).
