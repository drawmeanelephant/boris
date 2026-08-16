### Added

- Added a deterministic semantic plain-text projection over the Oliver typed
  document (`render.renderPlainText`, `html_body.renderSourcePlainText`) and
  wired it into Standard.site `textContent`: links keep their labels, images
  keep their alt text, fenced code stays verbatim, and Markdown/HTML chrome is
  dropped. The projection is omitted — never substituted with raw source or
  HTML — when rendering fails or exceeds the 256 KiB record bound. See the
  [plain-text projection contract](/docs/contracts/plain-text-projection.md).
