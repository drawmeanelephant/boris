### Changed

- The in-tree Cooklang adapter is gone: Boris now parses `.cook` bodies with
  Oliver's Cooklang stack (pinned as `.oliver_cooklang`) and renders/validates
  through the seam in
  [`src/cooklang_seam.zig`](/src/cooklang_seam.zig) — there is deliberately no
  second parser in Boris. Malformed structure (an unclosed `{`, `(`, or `[-`,
  or a body-only frontmatter fence) now **degrades to literal text with a
  structured warning** instead of failing the build with `ECOOKLANG`, matching
  Oliver's documented behavior; refusals are limited to what protects published
  output (control characters, invalid recipe references, empty timers or
  sections, and the IR bounds). See
  [the Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md)
  and [the Oliver renderer contract](/docs/contracts/oliver-renderer.md).
