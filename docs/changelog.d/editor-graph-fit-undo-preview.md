<!--
Filename: editor-graph-fit-undo-preview.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- Editor graph map opens at a readable zoom (50% floor) centered on the active
  page while Fit still shows the whole graph; typing coalesces into one undo
  step per phrase; a cold launch restores the last author-owned file from the
  disposable state root (or `content/index.md`); and an existing `dist/` tree
  is framed as stale instead of an empty idle preview. Links: [the editor-host
  contract](/docs/contracts/editor-host.md), [the editor
  guide](/content/guides/editor.md).
