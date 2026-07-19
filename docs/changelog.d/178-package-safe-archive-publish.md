### Fixed

- Review package archive publish no longer deletes the live tar before the
  replacement is complete; install uses move-aside so a failed write preserves
  any previous archive. Links:
  [package module](/src/package.zig),
  [release gate](/docs/RELEASE-GATE.md).
