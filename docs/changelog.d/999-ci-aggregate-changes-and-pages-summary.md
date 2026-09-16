### Fixed

- The required CI aggregate now depends on the `changes` path-filter job and
  fails when it fails, so a broken change-detection step can no longer wave the
  skipped conditional lanes through as green; PR body edits (`edited`) rerun
  the workflow so the issue-close lint revalidates the current body; and the
  optional GitHub Pages audit summary reports the actual `deploy-pages` step
  outcome instead of an unconditional success line after a failed deployment
  ([the CI workflow](/.github/workflows/ci.yml), [the Pages
  workflow](/.github/workflows/github-pages.yml)).
