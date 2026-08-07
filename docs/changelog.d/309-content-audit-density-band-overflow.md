<!--
Filename: 309-content-audit-density-band-overflow.md (pr-number is the real PR number)
Keep exactly one category heading.
-->

### Fixed

- [`boris-content-audit`](/tools/content-audit/) rejects policy `density_bands`
  values above 4294967295 (u32 max) as a malformed policy (exit 4) instead of
  trapping in Debug/ReleaseSafe builds or silently truncating in unchecked
  builds; band values must be positive, strictly ascending, and fit an
  unsigned 32-bit count.
