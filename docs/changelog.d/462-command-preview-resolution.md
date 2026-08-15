### Fixed

- The [editor](/content/guides/editor.md) dirty-buffer resolution dialog now
  also covers running Boris commands and rebuilding the preview: instead of
  only a status warning, running a command or rebuilding while the active
  buffer has unsaved changes offers Save & Run / Discard & Run (or Save &
  Rebuild / Discard & Rebuild) and Cancel
  ([#462](https://github.com/drawmeanelephant/boris/issues/462)).
