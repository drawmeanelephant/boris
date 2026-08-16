# TLS fixtures for the `wss://` conformance test

These are **test-only credentials** for the local TLS mock relay used by the
Nostr publish conformance matrix (`src/nostr_publish_matrix_test.zig`). They
have no real-world value: the CA and leaf keys are committed so the test can
pin the CA deterministically without touching the system trust store, and
the leaf is bound to `localhost` only (SAN `DNS:localhost`).

| File        | Purpose                                                        |
| ----------- | -------------------------------------------------------------- |
| `ca.pem`    | Self-signed test CA (`CN=Boris Nostr Test CA`), ECDSA P-256.   |
| `server.pem`| Leaf certificate for `CN=localhost` (RSA-2048), signed by `ca.pem`. |
| `server.key`| Unencrypted RSA-2048 private key for `server.pem`.             |

The leaf is **RSA-2048, not ECDSA**: the mock relay runs on the system
Python, whose LibreSSL (2.8.x on macOS) has no TLS 1.3 and therefore needs a
TLS 1.2 cipher; the only TLS 1.2 suites Boris offers are `ECDHE_RSA_*`, which
require an RSA server certificate. An RSA leaf also works fine when the
relay is later run on a TLS 1.3-capable stack.

The conformance test reads `ca.pem` and injects it as an extra trusted CA
(`ws.Limits.TlsOptions.extra_ca_pem`), connects to `wss://localhost:<port>`,
and asserts the full publish round-trip completes. A second test connects to
`wss://127.0.0.1:<port>` and asserts the client refuses: the leaf has no IP
SAN, so hostname verification fails closed.

## Regenerating

Valid until **August 2036**; regenerate (with at least `-sha256` signatures)
if they ever expire or the key material is compromised:

```sh
cd docs/contracts/fixtures/nostr-publication/tls
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -new -x509 -sha256 -key ca.key -out ca.pem -days 3650 \
    -subj "/CN=Boris Nostr Test CA"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
printf 'subjectAltName=DNS:localhost\n' > san.cnf
openssl x509 -req -sha256 -in server.csr -CA ca.pem -CAkey ca.key \
    -CAcreateserial -out server.pem -days 3650 -extfile san.cnf
rm -f server.csr san.cnf ca.srl
openssl verify -CAfile ca.pem server.pem
```

The leaf must keep SAN `DNS:localhost` and **no IP SAN**: the negative
hostname-mismatch conformance test depends on `127.0.0.1` not verifying.
