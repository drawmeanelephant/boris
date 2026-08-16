### Added

- Added offline NIP-23 signing: `boris nostr sign --plan PLAN --key-stdin`
  reads the plan artifact from `boris nostr plan`, reads the secret key once
  from stdin (hex or `nsec`, never argv/profile/env), and writes a
  signed-event bundle with the exact NIP-01 event id and BIP-340 signature
  for every article (bitcoin-core/secp256k1 `v0.8.0`, pinned; fresh aux
  randomness, context randomization, signature self-verification before any
  bundle is written). `--prior` reuses unchanged prior events and enforces
  the strict `created_at` update-ordering tie-break for changed intentions.
  See the [Nostr publication contract](/docs/contracts/nostr-publication.md).
