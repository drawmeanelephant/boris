<!--
Filename: 765-asset-sweep-unreferenced-note.md
-->

### Changed

- Unsafe content-local SVG diagnostics now say
  `(file not referenced by any page)` when the offending file's path appears
  nowhere in the owning page's source, distinguishing dead files from live
  ones; the discovery-time whole-sibling-tree sweep is now stated in the
  [content-local assets contract](/docs/contracts/content-local-assets.md).
  Fail-closed behavior and exit codes are unchanged. Issue #765.
