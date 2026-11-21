### Changed

- CI no longer reruns itself: editing a PR body reruns only the split-out `pr-issue-close lint` workflow, pushes to `main` no longer cancel each other's runs, `build-and-test` drops two steps already covered by `zig build test`, and [changelog fragments](/docs/changelog.d/README.md) are named by slug with no PR number, so they never need a rename push.
