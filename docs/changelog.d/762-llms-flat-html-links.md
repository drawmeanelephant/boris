<!-- Filename: 762-llms-flat-html-links.md -->

### Fixed

- `--llms` export now emits root-relative `.html` links (the same flat
  output-relative paths as the HTML target) instead of pretty `/id/`
  directory URLs, so `llms.txt` links resolve against a default static serve
  of the built site. Links: [the contract](/docs/contracts/llms-txt.md).
