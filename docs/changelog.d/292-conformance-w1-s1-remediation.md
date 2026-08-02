### Fixed

- Watch mode now treats a missing include (`error.IncludeFailed`) as a
  recoverable content failure: the watcher stays alive for author correction,
  preserves the previously valid published output, and recovers in the same
  process session instead of exiting. The C06 same-session watch case proves
  the full lifecycle. Links:
  [watch-mode contract](/docs/contracts/watch-mode.md).
- Unsafe content-local SVG rejection now exits as a content failure (exit 1)
  instead of being misclassified as system I/O (exit 3): `AssetUnsafeSvg`
  maps to the content-error arm of `mapHtmlError`, and the multi-target
  aggregate classifies it as content, so no generic I/O summary line is
  printed. All nine rejected SVG constructs stay rejected and uncommitted,
  and the inert Unicode SVG case is unchanged. Links:
  [content-local-assets contract](/docs/contracts/content-local-assets.md),
  [conformance report](/docs/audits/publication-conformance/REPORT.md).
