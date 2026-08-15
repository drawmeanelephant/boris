# AT Protocol OAuth core contract

**Status:** normative foundation slice; host transport, session persistence,
interactive login, and record publication are future adapters.

This contract defines Boris's portable AT Protocol OAuth cryptographic core and
the boundary that future local interactive publishing must preserve. It does
not add a CLI command, perform network access, store credentials, or amend an
existing publication artifact schema.

The core is exported as the Zig module `atproto_oauth`. It compiles for the
ordinary Boris target and under the repository's `wasm32-freestanding` gate.
It may use allocator-backed memory, `std.crypto`, hashing, base64url, and pure
byte validation. It must not import or consult HTTP, DNS, files, processes,
environment variables, a wall clock, global randomness, or operating-system
credential services.

## Capability boundary

The future client is split across these two ownership domains:

| Portable protocol core | Host adapter |
|---|---|
| PKCE S256 | Cryptographically secure entropy |
| P-256 public JWK and RFC 7638 thumbprint | Unix time |
| ES256 compact JWS | HTTPS and DNS policy |
| DPoP claim construction and access-token hash | Loopback callback listener |
| Bounded signing-input validation | Browser/user handoff |
| Protocol state transitions | Locked, atomic secret storage |

Host capabilities are explicit inputs. Tests and freestanding consumers may
supply deterministic values; production adapters must supply fresh secure
entropy for the session key, PKCE verifier, OAuth state, each DPoP `jti`, and
each ECDSA signing-noise value. None may silently fall back to a constant,
deterministic fixture, wall clock, or process-global generator.

The portable core never owns a network connection or credential file. This is
the compatibility seam for another Zig operating system: its native entropy,
clock, transport, callback, and secure-store services can sit behind the same
boundary without replacing the OAuth implementation.

## Implemented primitives

`pkceFromEntropy` maps exactly 32 entropy bytes to a 43-byte unpadded base64url
verifier and its SHA-256 challenge. `pkceChallenge` accepts only the RFC 7636
unreserved verifier alphabet and lengths 43 through 128.

`keyPairFromEntropy` deterministically derives an ES256 key pair from exactly
32 caller-supplied entropy bytes. Deterministic derivation does not make fixed
seeds acceptable in production. One key belongs to one OAuth session and must
remain bound to every access and refresh token in that session.

`publicJwk` emits only the public P-256 `x` and `y` coordinates. The JOSE header
adds fixed `kty: EC` and `crv: P-256` members and must never include the private
`d` member. `jwkThumbprint` hashes the lexicographically ordered canonical JWK
required by [RFC 7638](https://www.rfc-editor.org/rfc/rfc7638).

`buildDpopProof` emits a three-segment compact JWS with:

- `typ: dpop+jwt`, `alg: ES256`, and the public JWK in the protected header;
- `jti`, uppercase `htm`, query/fragment-free `htu`, and integer `iat` claims;
- `nonce` only when a server nonce is supplied;
- `ath` only when an access token accompanies a protected-resource request;
- an unpadded base64url encoding of the raw 64-byte `r || s` ES256 signature,
  never a DER signature.

Every proof requires caller-supplied signing noise and a unique caller-supplied
`jti`. The target URI accepts normalized ASCII `https://`, plus `http://` for a
future explicitly loopback-scoped development client. User information,
control bytes, malformed percent escapes, backslashes, non-HTTP schemes, and
oversized targets are rejected at the signing boundary. Query and fragment
components are not signed, as required by
[RFC 9449](https://www.rfc-editor.org/rfc/rfc9449).

The `ath` claim is unpadded base64url SHA-256 over the exact access-token bytes.
Tokens are bounded to 16 KiB at this layer. DPoP nonces use the RFC header-value
alphabet and are bounded to 1 KiB. These bounds are rejection rules, not
truncation rules.

## Future interactive client requirements

The first host integration is a native public client with authorization code,
PKCE S256, pushed authorization requests, and DPoP. Its local login surface is
DID-only (`did:plc` and `did:web`) and requests exactly:

```text
atproto include:site.standard.authFull
```

The Standard.site permission is defined by its
[permission contract](https://standard.site/docs/permissions/). The complete
flow must follow the current
[AT Protocol OAuth profile](https://atproto.com/specs/oauth) and keep the
expected DID, resolved PDS, authorization-server issuer, exact client ID,
granted scopes, tokens, and DPoP key bound as one session.

Local interactive v1 uses an ephemeral IPv4 loopback callback and the ATProto
localhost client-metadata convention. Authorization-server support for that
convention is optional. Rejection must produce an explicit compatibility error;
it must not fall back to an app password, export a token, or weaken the redirect
binding. A hosted callback or installed custom URI scheme is a separate future
client profile.

Authorization-server and PDS nonces are separate per-origin state. A
`use_dpop_nonce` response permits one retry with the newly supplied nonce and a
fresh proof. Refresh tokens are treated as rotating, single-use credentials;
future persistence must lock refresh, durably mark an in-flight exchange, and
fail closed after an ambiguous timeout.

## Test and acceptance surface

The foundation gate is:

```text
zig build test-atproto-oauth
```

It covers the RFC 7636 PKCE vector, the public-key/thumbprint values published
in RFC 9449, P-256 JWK shape, query/fragment removal, access-token hashing,
nonce and input bounds, and verification of the emitted raw ES256 signature.
The same gate compiles the module for `wasm32-freestanding` so an accidental
host dependency fails mechanically.

Future host slices add deterministic in-process tests for discovery, SSRF and
redirect policy, loopback callback parsing, nonce rotation, session locking,
refresh crash recovery, diagnostic redaction, and mock end-to-end publication.
Automated tests must not require internet access. Live PDS compatibility is a
separate recorded manual gate using dedicated test identities.
