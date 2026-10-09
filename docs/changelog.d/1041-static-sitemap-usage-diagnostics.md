### Fixed

- Static-directory and sitemap-path usage failures (`StaticSymlink`, `StaticDirMissing`, `SitemapOutputCollision`, and siblings) now keep their specific error and report `EUSAGE` diagnostics naming the offending static/sitemap path, instead of collapsing into `LayoutSelectionFailed` with `ELAYOUT` diagnostics and the layout path. See [the diagnostics contract](/docs/contracts/diagnostics.md) (Fixes #1036).
