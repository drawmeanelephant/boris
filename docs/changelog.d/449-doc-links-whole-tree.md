### Changed

- The `zig build test-doc-links` guard now walks every authored Markdown
  file under `docs/` (contracts, audits, dogfood, changelog.d, top-level
  docs) instead of just the README and authoring spine, so internal links
  rot loudly repo-wide. The first full-tree run surfaced and fixed real
  rot (a broken Trunk/Satellite anchor in `MIGRATION.md`, a deleted
  `src/cooklang.zig` reference, and a changelog.d-relative contract link);
  generated evidence code maps and fixture test data are skipped by design.
