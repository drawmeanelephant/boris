### Fixed

- Frontmatter's closing `---` must be a complete (newline-terminated) line, matching the opening-fence rule and the contract wording: a file whose last line is `---` with no trailing newline now fails closed with `EFRONTMATTER` ("unclosed frontmatter") instead of being silently accepted with an empty body — ending the asymmetry where `---<EOF>` closed but `---\r<EOF>` did not. Links: [the frontmatter contract](/docs/contracts/frontmatter.md), [#852](https://github.com/drawmeanelephant/boris/issues/852).
