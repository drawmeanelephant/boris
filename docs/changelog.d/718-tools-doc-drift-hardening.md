### Fixed

- Correct content-audit exit-4 and duplicate-key documentation, classify oversized files before UTF-8 validation, fail closed on unreadable symlink-walk components, free leaked policy arrays, and require path-segment boundaries in docs-maintenance file classification. See [`tools/content-audit/src/frontmatter.zig`](/tools/content-audit/src/frontmatter.zig) and [#718](https://github.com/drawmeanelephant/boris/issues/718).
