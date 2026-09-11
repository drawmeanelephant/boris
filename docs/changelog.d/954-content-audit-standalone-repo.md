### Changed

- `boris-content-audit` graduated to its own repository
  ([`drawmeanelephant/boris-content-audit`](https://github.com/drawmeanelephant/boris-content-audit),
  tagged `v0.8.2`, issue [#834](https://github.com/drawmeanelephant/boris/issues/834)).
  The tool tree left with its history (21 commits, moved via
  `git filter-repo`), and this repo dropped its one-shot gate, its
  `content-audit` / `test-content-audit` build steps, and its
  `content-audit-test` CI lane plus the strict aggregate requirement on it.
  The tool keeps its own build, tests, and unconditional both-OS CI lane, and
  pins the closed frontmatter and identity grammar by Boris release tag.
  Links: [the tools registry](/docs/tools-registry.md),
  [the split plan](/docs/plans/content-audit-standalone-repo.md).
