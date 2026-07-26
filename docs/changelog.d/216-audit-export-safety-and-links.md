### Fixed

- Hardened RAG, Context, llms.txt, and HTML target publication against
  content-tree aliasing, workspace escapes, and absolute-path symlink
  components; incremental HTML now tracks resolved ordinary Markdown links
  without exporting them as semantic graph edges. See the
  [documentation-link contract](/docs/contracts/documentation-links.md) and
  [HTML output contract](/docs/contracts/html-output.md).
