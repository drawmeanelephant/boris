<!-- Filename: 757-scripts-symlink-safe-workspace-paths.md -->

### Fixed

- Test and release-gate scripts resolve workspace roots and output paths
  physically (`pwd -P`), so checkouts reached through symlinked paths (e.g.
  macOS `/tmp` → `/private/tmp`) no longer false-fail the compiler's
  `WorkspaceEscape` target-containment guard. Links:
  [scripts/test-reference-theme-layout.sh](/scripts/test-reference-theme-layout.sh),
  issue #757.
