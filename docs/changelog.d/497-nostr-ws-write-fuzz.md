### Changed

- Hardened the write side of the in-repo RFC-6455 client and its conformance
  evidence:
  - `sendText` now fragments outgoing text messages larger than
    `limits.max_fragment_bytes` (default 64 KiB) on the wire: an initial
    text frame with FIN clear, then continuation frames, the last with FIN
    set — RFC 6455 §5.4 requires every server to accept fragmented client
    messages. Control frames are never fragmented, and the message ceiling
    (`max_message_bytes`) and frame ceiling (`max_frame_payload`) still
    bound both directions.
  - The frame encoder now emits the 8-byte extended-length form for
    payloads at or above 64 KiB (the `127` form was dead code behind a
    `maxInt(u16)` guard), matching the parser's 64-bit length handling.
  - Added write-side fuzz coverage: a recording mock relay drives random
    payloads and fragmentation patterns (fragment sizes 1 through 65536,
    payload lengths across every length-encoding boundary) through
    `sendText` over a real loopback socket, and asserts what a server would
    receive — mask bit, FIN sequence, length codes, and the unmasked
    payload — is byte-exact against what was sent.
  - Added a write-deadline conformance test: a relay that completes the
    handshake and then stops reading forces the client's flush to block;
    the per-write deadline must interrupt it mid-flush and surface
    `WriteTimeout` instead of hanging.
  - The conformance mock relays (in-repo and the Python TLS relay) now
    reassemble fragmented client messages, as a conforming server must.
