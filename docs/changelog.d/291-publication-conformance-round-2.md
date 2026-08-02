### Added

- Extend the executable publication-conformance evidence suite with C01
  (valid Textile HTML), C05 (layout precedence), C06 (cache/watch failure
  paths), and C07 (asset collisions and SVG policy), including a bounded
  watch-lifecycle test and two remediation cards for confirmed defects
  (watcher exit on failed include rebuild; active-SVG rejection exit class).
  The C05 and C06 incremental cases reuse one output directory per scenario
  (an `--incremental` first publication followed by `--incremental` rebuilds
  into the same target), the exit trap reaps every retained watcher PID, and
  the watch-failure case pins the exact exit code. Links:
  [conformance report](/docs/audits/publication-conformance/REPORT.md),
  [watch-mode contract](/docs/contracts/watch-mode.md),
  [content-local-assets contract](/docs/contracts/content-local-assets.md),
  [textile-compatibility contract](/docs/contracts/textile-compatibility.md).
