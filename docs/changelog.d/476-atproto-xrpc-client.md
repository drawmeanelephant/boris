### Added

- Added a typed atproto XRPC record client (get/put/deleteRecord) with
  DPoP-authenticated requests, nonce retry, origin pinning, and an offline
  mock transport with a freestanding compile gate. See the
  [OAuth core contract](/docs/contracts/atproto-oauth.md) for the
  authorization foundation it builds on.
