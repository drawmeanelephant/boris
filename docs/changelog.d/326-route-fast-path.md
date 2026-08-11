### Changed

- Common published local links now use a caller-owned route-resolution fast
  path, while escaped and normalized references retain the existing slow path.
  See the [documentation-links contract](/docs/contracts/documentation-links.md).
