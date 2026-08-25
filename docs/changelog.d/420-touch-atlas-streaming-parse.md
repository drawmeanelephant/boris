### Fixed

- The Touch Atlas derivation no longer fails with `InvalidChecksReport` for
  checks reports whose skipped string values straddle the 64 KiB streaming
  chunk boundary — the failure previously moved with the report's byte
  length (a `public`-target report died while the identical `default`-target
  content parsed). The streaming parser now consumes partial string/number
  tokens to their completing token instead of treating them as whole values
  (#420, #417).
