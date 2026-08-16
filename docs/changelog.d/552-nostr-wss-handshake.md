### Fixed

- `boris nostr publish` no longer treats a TLS 1.3 `NewSessionTicket` (or
  a partial ciphertext record) as a failed WebSocket upgrade. `wss://`
  relays can complete the HTTP 101 handshake. See the
  [Nostr publication contract](/docs/contracts/nostr-publication.md) and
  [#552](https://github.com/drawmeanelephant/boris/issues/552).
