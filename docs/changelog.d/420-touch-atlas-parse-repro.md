### Added

- Added a standalone reproducer for the Touch Atlas streaming-checks parse
  failure ([#420](https://github.com/drawmeanelephant/boris/issues/420)): a
  synthesized 216-finding `checks.json` that dies at finding #207 when its
  `owner` value straddles the 64 KiB streaming buffer, with a 13-byte-longer
  control that parses cleanly. (Retired with the canary in the same
  unreleased window; see the #420 resolution in
  [the Touch Atlas contract](/docs/contracts/publication-touches.md).)
