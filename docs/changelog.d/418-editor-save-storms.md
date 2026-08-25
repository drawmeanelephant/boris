### Fixed

- The [editor](/content/guides/editor.md) serializes overlapping saves so a
  second Save cannot race the fingerprint, and one corrupt recovery snapshot
  no longer hides the valid ones
  ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
