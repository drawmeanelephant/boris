### Fixed

- Nostr publish now records the SHA-256 of the signed-bundle bytes (not a
  copy of the plan digest), classifies a plain relay `OK false` as
  `rejected` and a mismatched OK as `wrong-id`, re-verifies reused prior
  signatures, refuses a bundle whose article set does not match the plan,
  and rejects incoming WebSocket frames larger than the receive buffer.
  See the
  [Nostr publication contract](/docs/contracts/nostr-publication.md).
