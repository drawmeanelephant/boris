### Fixed

- Fix Starlight migration-lab frontmatter parsing so the earliest `---` terminator wins instead of a whole-file CRLF probe; an LF-closed file whose body contains a CRLF horizontal rule no longer swallows the body. See [`tools/migration-lab/starlight.zig`](/tools/migration-lab/starlight.zig) and [#713](https://github.com/drawmeanelephant/boris/issues/713).
