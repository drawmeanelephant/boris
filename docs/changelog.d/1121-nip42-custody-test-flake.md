### Fixed

- De-flaked the NIP-42 process custody fault tests: they asserted
  post-key-read outcomes against a 200ms plan `timeout_ms` that scheduler
  starvation alone can consume, and now use the 2000ms non-timeout budget
  convention from #1075. Test-side only; the custody ordering in
  [the Nostr publication contract](/docs/contracts/nostr-publication.md)
  is unchanged.
