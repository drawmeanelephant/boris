### Fixed

- The [GitHub Pages target](/docs/contracts/publication-platforms.md)
  workflow installs Zig **0.17.0** in both the build job and the optional
  deployment-observer job, matching `minimum_zig_version` and the `ci.yml`
  pins. The `0.16.0` pins left over from before the 0.17 toolchain migration
  (#1026) failed every push-to-`main` run at `zig build`, leaving the live
  Pages site undeployed since 2026-10-07 (#1033).
