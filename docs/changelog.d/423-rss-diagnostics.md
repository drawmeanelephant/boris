### Fixed

- Missing RSS channel metadata now reports the actual missing options
  (`--site-url`, `--rss-title`, `--rss-description`) instead of a phantom
  "missing value for --rss" / "--rss-path". The same misdiagnosis class
  is fixed for `--sitemap` without `--site-url` and a partial
  `--pages-base-*` trio. Mode flags are never blamed for unknown-option
  errors that occur after them.
