### Fixed

- Obsidian migration lab: resolve unambiguous **path-suffix** wiki targets
  (and sanitized entity-id suffixes), classify Templater/`${…}` wiki targets as
  `plugin_template` instead of unresolved, and **disambiguate colliding entity
  ids** so generated content paths never clobber — with content-byte
  determinism coverage in the synthetic fixture. See
  [migration-lab README](tools/migration-lab/README.md) and
  [mini-obsidian fixture notes](tools/migration-lab/fixtures/mini-obsidian-README.md).
