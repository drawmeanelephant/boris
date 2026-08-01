### Added

- Added a deterministic target-owned HTML payload inventory with exact byte
  sizes and SHA-256 digests; see the [publication artifact inventory contract](/docs/contracts/publication-artifacts.md).
- Ensured the inventory is the last target payload replaced, so a failed
  replacement cannot expose a next-generation inventory for an older target.
- Documented the existing per-file staged-publish limitation: a mid-tree
  filesystem failure can leave earlier payload replacements visible, while the
  prior inventory remains authoritative for the last successful publication.
