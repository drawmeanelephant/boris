<!--
Filename: 833-parser-package-module.md (draft; rename to the PR number when the
PR exists). Keep exactly one category heading.
-->

### Added

- Boris now publishes the frontmatter parser as a stable package module
  (`parser`, exposed through `build.zig` via `b.addModule("parser", …)` and
  pinned by a package-API test) so dependent builds — including the migration
  laboratory, which is being split into its own repository — can consume it
  through `build.zig.zon` instead of a relative source path. See [the
  standalone-repo plan](/docs/plans/migration-lab-standalone-repo.md).
