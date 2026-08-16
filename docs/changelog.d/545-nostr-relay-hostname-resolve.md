### Fixed

- `boris nostr publish` resolves named relays (`wss://relay.example.org`,
  `ws://localhost`) through DNS instead of treating the hostname as an IP
  literal. See the
  [Nostr publication contract](/docs/contracts/nostr-publication.md) and
  [#545](https://github.com/drawmeanelephant/boris/issues/545).
