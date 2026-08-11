### Fixed

- Enforced the normalized GitHub Pages origin and base path across generated
  HTML/public metadata, sitemap, RSS, and location-aware `llms.txt` output;
  mismatches now fail before publication. Hosted `llms.txt` links use Boris's
  actual `.html` output routes, and rendered `<base href>` context is audited
  with the first effective base, including fragment-only and empty references
  that resolve to a base document. See the [GitHub Pages contract](/docs/github-pages.md).
