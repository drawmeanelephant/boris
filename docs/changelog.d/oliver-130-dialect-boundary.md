### Changed

- Locked Boris's Oliver 1.3.0 Markdown dialect boundary with regression tests in
  [`src/render.zig`](/src/render.zig) and normative wording in the
  [Oliver renderer contract](/docs/contracts/oliver-renderer.md#explicit-dialect-allowlist-and-footnote-pairing):
  `markdown_options` stays on the explicit four-extension allowlist (never
  Oliver's `obsidian` preset), Obsidian-only syntax remains literal across
  `.html`, `.xhtml`, `.html4_strict`, and plain-text projections, `.footnotes`
  stays paired between parse and render options across all profiles, and GFM
  table delimiter forms remain intact.
