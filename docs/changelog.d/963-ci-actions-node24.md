### Changed

- Bumped the CI workflow's `actions/checkout`, `actions/setup-node`, `actions/upload-artifact`, and `dorny/paths-filter` to their current Node 24 releases and pinned every action in [the CI workflow](/.github/workflows/ci.yml) by commit SHA, clearing the runner's Node 20 deprecation annotations (#963). `mlugg/setup-zig` stays pinned at its latest upstream v2.2.1, which still declares Node 20.
