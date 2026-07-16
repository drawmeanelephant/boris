### Fixed

- Release-gate step 7 detects Git checkouts with
  `git rev-parse --is-inside-work-tree` so linked worktrees (where `.git` is a
  file, not a directory) still run the tracked/generated cleanliness checks.
  Coverage:
  [scripts/test-release-gate-git-detection.sh](/scripts/test-release-gate-git-detection.sh);
  gate:
  [scripts/release-gate.sh](/scripts/release-gate.sh).
