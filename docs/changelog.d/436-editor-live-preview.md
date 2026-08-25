<!--
Filename: 436-editor-live-preview.md
Keep exactly one category heading.
-->

### Added

- Added the Boris Editor's loopback live-preview fallback with build-on-save,
  last-good preservation, and explicit stale/failure states; the embedded
  preview frame is allowed through the host Content-Security-Policy and its
  real-browser rendering is covered by the integration gate. See
  [the preview workflow](/editor/README.md).