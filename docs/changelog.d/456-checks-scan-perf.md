### Fixed

- The publication `checks` evidence phase no longer rescans each page from
  byte 0 per id/reference: `doctor.scanPage` now advances an incremental
  (line, column) cursor (O(page length) instead of O(references × page
  length)), and id-fragment lookups use a binary search over the sorted id
  list. A 2000-page ReleaseFast build dropped from ~231 s to ~9 s (checks
  226.6 s → 3.4 s) with identical `checks.json` output (issue #456).
