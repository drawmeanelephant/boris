### Changed

- Hardened the in-repo RFC-6455 client and its conformance evidence:
  - The publish transport now owns its socket reader/writer and TLS state in
    one heap box (`ws_client.TlsBox`). `std.crypto.tls.Client` stores
    `*Reader`/`*Writer` pointers to the socket interfaces inside itself, and
    `connect` returns the client by value; without the box those pointers
    dangled into the dead stack frame the moment `connect` returned, so
    every post-handshake `wss://` read operated on stale memory (observed as
    a spurious `ReadFailed` on the first frame read). The fix is a stable
    box the client value points at; the plain `ws://` path and all plaintext
    matrix scenarios were already green and stay green.
  - Added seeded parser fuzz coverage: `encodeFrame`/`parseFrame` round-trip
    with random opcodes, lengths, mask bits, and fragmentation flags, plus a
    hostile "fuzz stream" matrix scenario that feeds random bytes to the
    client's frame reader and asserts it fails closed without a hang or
    crash.
  - Added a real `wss://` end-to-end conformance test: a TLS mock relay
    (`scripts/nostr-mock-relay-tls.py`, Python `ssl`) bound to loopback,
    pinned by committed self-signed test credentials
    (`docs/contracts/fixtures/nostr-publication/tls/`, RSA-2048 leaf for the
    system Python's TLS 1.2-only LibreSSL). The positive test asserts the
    full publish round-trip completes over TLS; the negative test pins the
    same CA but connects to `127.0.0.1` and asserts hostname verification
    fails closed (`TlsFailed`).
