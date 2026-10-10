### Fixed

- Publication-profile parsing no longer reports an allocation failure during
  the initial JSON parse as malformed input — the run now exits 3 (the
  system-error class) instead of the exit-2 usage class — and the `head`
  declaration grammar rejects the wrong-type values `std.json` used to
  coerce: numeric and numeric-string enum values (`type: 0`, `type: "0"`) and
  byte-array strings (`title: [116,105,116]`) now fail with a diagnostic that
  names the field, per the
  [head metadata contract](/docs/contracts/head-metadata.md).
