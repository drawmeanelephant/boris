<!--
Filename: 771-cli-diagnostics-attribution.md
Source PR: https://github.com/drawmeanelephant/boris/pull/771
Closes #761, #764, #766.
-->

### Fixed

- CLI usage diagnostics are self-attributing: out-of-workspace `--theme` / `--html-layout` values name their own flag instead of a scanned argv token (`invalid value for --input`), and unambiguous conflicting-options errors name both tokens as typed (`check conflicts with --theme`); the `--help` conflict matrix gains the analyzer×HTML-selector and HTML-selector×explicit-`--out` rows. See [the CLI contract](/docs/contracts/cli.md).

### Docs

- `boris --help` documents the frontmatter `status:` enum (`draft` | `published` | `archived`) and the draft visibility rule — drafts render but stay out of nav, search, sitemap, RSS, and publication projections; behavior unchanged and still normative in [the frontmatter contract](/docs/contracts/frontmatter.md).
