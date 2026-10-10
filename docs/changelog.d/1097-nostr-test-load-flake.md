<!--
Filename: <pr-number>-<short-kebab-case-summary>.md
-->

### Fixed

- `zig build test` no longer flakes under machine load: the Nostr publication
  matrix and auth-IPC tests stopped asserting on wall-clock timing. Plans that
  expect a non-timeout outcome now carry a deadline scheduler starvation cannot
  beat, stall scenarios drive a test-only clock instead of racing `sleep`, and
  promptness checks compare cross-thread event ordering rather than elapsed
  milliseconds. Product deadlines are unchanged. Links:
  [nostr publication contract](/docs/contracts/nostr-publication.md),
  [issue](https://github.com/drawmeanelephant/boris/issues/1075).
