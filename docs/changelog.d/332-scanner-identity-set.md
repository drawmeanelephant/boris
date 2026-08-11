### Fixed

- Replaced the scanner's linear directory-identity cycle checks with an inode
  identity set while preserving the documented symlink rejection and cycle
  precedence. See the [scanner contract](/docs/contracts/scanner.md).
