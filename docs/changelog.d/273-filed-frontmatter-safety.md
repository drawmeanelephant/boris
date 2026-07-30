### Fixed

- Make the bounded Filed.fyi migration lab reject invalid UTF-8, BOM-prefixed,
  malformed, duplicate-key, and unterminated frontmatter instead of emitting
  plausible pages; see [`tools/migration-lab/filed.zig`](/tools/migration-lab/filed.zig).
