<!--
Filename: repin-oliver-42cf472.md
Category: Changed
-->

### Changed

- Re-pinned the Markdown renderer dependency (Oliver) from `872b002` to
  `42cf472` on the `boris-markdown-extensions` branch. The move absorbs the
  branch's rebase onto current Oliver `main` and fixes repeated footnote
  references: each `[^label]` occurrence now gets a unique `fnref-N` /
  `fnref-N-2` id with one backref per reference instead of duplicate ids.
  Boris's seam error set gained Oliver's `RawHtmlNotXmlWellFormed` member
  (structurally unreachable under the HTML profile; tracked for exact surface
  parity). Pin table: [oliver-renderer.md](/docs/contracts/oliver-renderer.md).
