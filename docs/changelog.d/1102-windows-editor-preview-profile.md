<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- Editor host now compiles and runs its full test suite on Windows (Zig 0.17.0
  std shims for file permissions and wait4 status), and the Preview pane's
  rebuild honors a project's `boris.json` publication profile instead of
  assuming the default theme, so profiled projects preview correctly.
  Links: [editor host contract](/docs/contracts/editor-host.md).
