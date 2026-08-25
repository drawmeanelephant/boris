### Added

- `boris-editor` accepts an optional `open=<project-relative path>` fragment
  parameter on its launch URL; the shell opens that author-owned file on launch
  (unsafe paths are ignored with a status message, missing files surface the
  host's `file_not_found`, and the editor still boots to the project file
  list). See [the editor launch contract](/editor/README.md) and
  [issue #649](https://github.com/drawmeanelephant/boris/issues/649).
