### Fixed

- WordPress migration lab no longer silently drops WXR excerpts, sticky flags,
  or empty slugs: schema 3 records `excerpt` / `is_sticky` / `source_slug` /
  `post_date_gmt`, preserves excerpts in page bodies, and reports
  `excerpt_preserved` / `sticky_post` / `empty_slug`. Adds redistributable
  [`tools/migration-lab/fixtures/unit-wxr/`](tools/migration-lab/fixtures/unit-wxr/)
  unit matrix (WPTT research, not the full upstream corpus). See
  [`tools/migration-lab/README.md`](tools/migration-lab/README.md).
