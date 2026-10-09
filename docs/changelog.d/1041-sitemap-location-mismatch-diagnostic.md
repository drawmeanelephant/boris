### Fixed

- `build`/`validate --sitemap` with a `--site-url` that disagrees with the declared Pages publication location now emits an `EPUBLICATIONLOCATION` diagnostic naming both URLs instead of failing silently with a generic `EIO` report entry, and `watch` no longer labels the failure an unrecoverable I/O error. See [the diagnostics contract](/docs/contracts/diagnostics.md) (Fixes #1035).
