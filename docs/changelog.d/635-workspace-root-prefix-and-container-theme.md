<!--
Filename: 635-workspace-root-prefix-and-container-theme.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- `boris-job-runner build` now succeeds when the process cwd is the filesystem
  root. The workspace-prefix check in `hasAbsPathPrefix` required a component
  boundary after the prefix, so with cwd `/` (the container image's runtime
  environment) every absolute output path was rejected as `WorkspaceEscape`.
  The root is now a valid prefix for every absolute path, with boundary
  assertions added. The example container image also ships the default `boris`
  theme at `/themes/boris` — boris resolves the default layout against cwd —
  so a content-only source archive builds inside the image instead of failing
  `ELAYOUT`. See [the container-runner contract](/docs/contracts/cloudflare-container-runner.md)
  and [#300](https://github.com/drawmeanelephant/boris/issues/300).
