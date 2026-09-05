### Fixed

- Entity ids may no longer end with a page extension (`.md`, `.mdx`, `.textile`, `.cook`): such an id could byte-equal another page's `sourcePath`, conflating the incremental cache keys and silently missing rebuilds. `id:`/`parent:` frontmatter values, wiki-link targets, and every other id surface now reject the shape fail-loud with a located `EINVALIDPATH` (frontmatter) or `EREFERENCESYNTAX` (wiki link). Links: [the identity-and-paths contract](/docs/contracts/identity-and-paths.md), [#854](https://github.com/drawmeanelephant/boris/issues/854).
