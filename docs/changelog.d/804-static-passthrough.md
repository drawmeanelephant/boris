<!--
Filename: <pr-number>-static-passthrough.md (rename to the PR number when opened)
-->

### Added

- Added `--static-dir DIR` (#804): a declared directory of site-owned static
  files (`robots.txt`, `humans.txt`, `.well-known/`, …) copied byte-identically
  into the HTML target root, declared as `static-file` records in the artifact
  inventory, fail-loud on missing dirs, symlinks, unsafe paths, and collisions,
  with stale-file scrub on rebuild and a per-target `static.dir` profile field.
  Links: [the HTML output contract](/docs/contracts/html-output.md), the
  [publication artifact inventory contract](/docs/contracts/publication-artifacts.md),
  and the [CLI contract](/docs/contracts/cli.md).
