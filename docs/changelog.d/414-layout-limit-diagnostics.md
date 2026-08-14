### Fixed

- Layouts that exceed the `{{asset-url}}` / segment bounds now report the
  real reason: `LayoutTooManyAssetUrls` (max 16 occurrences) or
  `LayoutTooManySegments` (max 32 total segments), instead of the misleading
  `LayoutInvalidAssetUrl` / `LayoutUnknownMarker`. Both bounds are now pinned
  by unit tests. See
  [`templating-and-themes.md`](../contracts/templating-and-themes.md) §3.
