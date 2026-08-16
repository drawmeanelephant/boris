### Added

- Added online NIP-23 publishing: `boris nostr publish --plan PLAN
  --bundle BUNDLE` sends the exact signed events from a `nostr sign` bundle
  to the plan's configured relays over a bounded in-repo RFC-6455 WebSocket
  client (`ws_client.zig`, `std.net` + `std.crypto.tls` with hostname
  verification and system CA roots). Nothing is sent before the bundle is
  cross-verified against the plan (digest, expected pubkey, event ids,
  BIP-340 signatures). Every relay interaction is bounded by per-read
  deadlines and produces per-relay evidence; the run always reaches a
  `complete` / `partial` / `failed` / `incomplete` verdict, and relays that
  demand NIP-42 authentication are reported honestly as `auth-required`
  (unsupported in v1, #493) while the remaining relays are still attempted.
  A hostile mock-relay conformance matrix covers fragmented `OK`, Ping/Pong,
  Close-before-OK, masked server frames, timeout, malformed messages, wrong
  event ids, oversized frames, bad handshakes, retries with identical event
  bytes, and mixed multi-relay classification. See the
  [Nostr publication contract](/docs/contracts/nostr-publication.md).
