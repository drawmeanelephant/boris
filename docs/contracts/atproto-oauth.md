# AT Protocol OAuth core contract

**Status:** normative foundation slice; explicit-DID authority discovery is
implemented, while interactive login, session persistence, and record
publication remain future adapters.

This contract defines Boris's portable AT Protocol OAuth cryptographic core and
the boundary that future local interactive publishing must preserve. It does
not add a CLI command, perform network access, store credentials, or amend an
existing publication artifact schema.

The cryptographic core is exported as the Zig module `atproto_oauth`.
`atproto_identity` owns portable DID and metadata validation, and consumes the
small capability in `atproto_transport`. All three compile for the ordinary
Boris target; the crypto and identity/discovery side compile under the
repository's `wasm32-freestanding` gate.
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

## Authority discovery

The implemented milestone is deliberately narrower than an OAuth client:

```text
configured did:plc or did:web
  -> exact DID document
  -> validated ATProto PDS origin
  -> bound Protected Resource Metadata
  -> one Authorization Server origin
  -> bound Authorization Server issuer and required capabilities
```

`discover` accepts an explicit DID only. It does not reinterpret an arbitrary
string as a handle. Handle DNS TXT/HTTPS resolution and the mandatory
bidirectional handle-to-DID check are deferred; a later resolver can feed its
verified DID into the existing discovery path without changing the transport
or metadata validators. `alsoKnownAs` is ignored for authentication in this
slice.

The returned `DiscoveredAccount` contains only validated values: the exact DID,
PDS origin, Authorization Server origin, authorization endpoint, token
endpoint, and pushed-authorization-request endpoint. The result guarantees the
required `atproto`, authorization-code, refresh-token, S256, public/confidential
client-auth, client-metadata-document, PAR, issuer-response, and ES256 DPoP
capabilities. Raw JSON and arbitrary URL strings do not cross this boundary.

### DID methods and documents

Only `did:plc` and host-level `did:web` are accepted. PLC identifiers are the
24-character lowercase base32 identifier defined by the current PLC method.
ATProto's narrower `did:web` profile does not accept method paths or production
ports. Production parsing also rejects IP literals, single-label/local names,
reserved/local-use TLDs, controls, whitespace, user information, queries,
fragments, and ambiguous percent/path syntax. There is no production switch
that enables insecure localhost resolution.

`did:plc` resolves with one GET to
`https://plc.directory/{did}`. This trusts the PLC directory's current resolved
DID document. It does not download or cryptographically audit the PLC operation
log, implement rotation, or create/update a PLC identity. That narrower trust
boundary matches ordinary client resolution; operation-log audit remains an
explicitly separate capability.

Host-level `did:web:example.com` resolves only to
`https://example.com/.well-known/did.json`. General W3C `did:web` path and port
forms are intentionally outside the ATProto profile implemented here.

Every returned document must be a bounded JSON object whose `id` is byte-for-byte
the configured DID. The ordered `service` array is scanned for an ID equal to
`#atproto_pds` or `{did}#atproto_pds` and type
`AtprotoPersonalDataServer`. Per the current ATProto DID specification, the
first matching entry is authoritative and later entries are ignored. A malformed
first match fails closed. Unrelated services may use other DID-Core shapes and
are ignored.

### Origins and endpoints

A PDS or Authorization Server origin is a canonical production HTTPS origin,
not a general URL. Credentials, explicit default port 443, path (including a
trailing slash), query, fragment, IP literals, malformed hostnames, noncanonical
host casing, and encoded authority syntax are rejected. A non-default port is
allowed because the ATProto profile allows it. Endpoint URLs are separately
typed HTTPS values; user information, fragments, malformed escapes, encoded
slash/backslash/dot confusion, and dot path segments are rejected.

OAuth endpoint origins are not forced to equal the issuer origin. RFC 8414 and
the ATProto profile require those members to be valid HTTPS endpoint URLs but
do not require same-origin hosting. Any later network use of the token or PAR
endpoint still passes through the same connection-target policy.

Origin equality is intentionally explicit: accepted origins already use the
canonical grammar above, then equality is byte equality. The RFC 9728
`resource` value must equal the PDS origin exactly. The Authorization Server
metadata `issuer` must equal exactly the origin obtained from the Resource
Server metadata and used to construct the well-known request. There is no
suffix, prefix, case-folded, redirect-derived, or "close enough" comparison.

### OAuth metadata validation

Protected Resource Metadata is fetched with GET at
`/.well-known/oauth-protected-resource`. It must be status 200 exactly, use an
`application/json` media type, contain a `resource` exactly equal to the PDS
origin, and contain exactly one `authorization_servers` string. That string
must parse as a canonical HTTPS origin.

Authorization Server Metadata is fetched with GET at
`/.well-known/oauth-authorization-server`. It must also be status 200 exactly
and JSON. The validator requires:

- `issuer` exactly bound to the discovered Authorization Server origin;
- valid authorization, token, and PAR HTTPS endpoints;
- `response_types_supported` containing `code`;
- `grant_types_supported` containing `authorization_code` and `refresh_token`;
- `code_challenge_methods_supported` containing `S256`;
- `token_endpoint_auth_methods_supported` containing `none` and
  `private_key_jwt`;
- token-endpoint signing algorithms containing `ES256` and excluding `none`;
- `scopes_supported` containing `atproto`;
- `authorization_response_iss_parameter_supported`,
  `require_pushed_authorization_requests`, and
  `client_id_metadata_document_supported` all true;
- DPoP signing algorithms containing `ES256`; and
- optional `require_request_uri_registration` absent/true, never false.

These checks prove readiness for later PAR and token cards; they do not make a
PAR request or exchange a token.

## Transport and network policy

`atproto_transport.Client` exposes only the operation discovery needs: a GET at
an already validated URL, fixed bounded headers, a forbidden-redirect policy,
explicit response limits, and a whole-request timeout. Responses carry only a
status, bounded headers, and bounded body. `ScriptedMock` validates the exact
method, URL, headers, and redirect policy and can inject status/headers/body,
redirects, timeouts, failures, oversized inputs, and changed responses.

The native `atproto_transport_std` adapter owns a fresh `std.http.Client` and:

- loads no proxy environment configuration, cookie jar, credentials, or
  implicit authorization;
- uses platform TLS certificate verification and never downgrades HTTPS;
- disables automatic redirects and returns every 3xx as
  `RedirectRejected`; therefore cross-origin redirects, downgrade redirects,
  redirect loops, and oversized chains all terminate at the first hop;
- races the complete request against the explicit 15-second default timeout;
- disables response compression and reads into a fixed-capacity body buffer;
- classifies DNS, connection, TLS, timeout, unsafe-target, header, body, and
  malformed-response failures deterministically; and
- has no filesystem side effects beyond `std.http` reading the host's normal
  TLS trust material.

URL validation and connection-target validation are separate. Discovered URL
text may not contain an IP literal, localhost/private name, user information,
or non-HTTPS scheme. Independently, the native adapter replaces the socket
connect seam and examines every concrete DNS result immediately before the
connection. It rejects IPv4 unspecified, loopback, RFC 1918, link-local,
carrier-grade NAT, benchmark/documentation, multicast, and reserved ranges. It
rejects IPv6 unspecified, loopback, non-global, unique-local, link-local,
multicast, documentation, and private IPv4-mapped addresses. Only public IPv4
and conservative IPv6 global-unicast targets are eligible. This per-address
check also applies when DNS answers change; no claim is made that hostname
string validation prevents rebinding.

The checked-connect registry is bounded to eight simultaneously registered
host I/O contexts. Failure to install the connection hook fails closed before
an HTTP client is exposed. The adapter is currently a macOS/Linux host adapter,
not a freestanding network stack; DipshitOS can implement the same portable
capability with its own resolver, TLS, deadline, and socket-address policy.

All identity and discovery redirects are forbidden because the current PLC,
`did:web`, RFC 9728, RFC 8414, and ATProto profile endpoints are deterministic
and require an exact successful response. No redirect can downgrade, change
origin, reach a private address, loop, or consume a redirect budget.

Implementation limits are rejection bounds, never truncation or protocol
claims:

| Input | Limit |
|---|---:|
| DID or URL | 2,048 bytes |
| DID document body | 256 KiB |
| Resource Server metadata body | 64 KiB |
| Authorization Server metadata body | 64 KiB |
| Response headers | 64 |
| Total response-header name/value bytes | 16 KiB |
| One response-header name | 256 bytes |
| One response-header value | 8 KiB |
| One JSON string/value token | 16 KiB |
| JSON object/array nesting | 16 levels |

There is no persistent or in-memory discovery cache. Every `discover` call
resolves the DID and both metadata documents anew, so changed identity data is
not silently retained across operations. A future session layer may add a
bounded, explicit cache with the ATProto recommendation of less than ten
minutes for authorization flows.

## Specification baseline

This implementation was re-grounded on 2026-08-14 against these exact primary
documents. ATProto pages and the did:web community draft do not publish a
stable revision identifier, so the retrieval date is the recorded revision:

- [AT Protocol DID](https://atproto.com/specs/did), unversioned current page,
  retrieved 2026-08-14;
- [AT Protocol OAuth](https://atproto.com/specs/oauth), unversioned current
  page, retrieved 2026-08-14;
- [AT Protocol Handle](https://atproto.com/specs/handle), unversioned current
  page, retrieved 2026-08-14 (architecture input only; resolution deferred);
- [AT Protocol HTTP API/XRPC](https://atproto.com/specs/xrpc), unversioned
  current page, retrieved 2026-08-14 (no XRPC call is made in this slice);
- [`did:plc` method specification v0.3.0](https://web.plc.directory/spec/v0.1/did-plc),
  December 2025 (the published URL retains `/v0.1/`);
- [Web DID Method Specification](https://w3c-ccg.github.io/did-method-web/),
  W3C CCG editor draft retrieved 2026-08-14, narrowed by ATProto's host-only
  profile;
- [W3C DID Core 1.0](https://www.w3.org/TR/2022/REC-did-core-20220719/), W3C
  Recommendation dated 2022-07-19;
- [RFC 9728](https://www.rfc-editor.org/rfc/rfc9728), OAuth 2.0 Protected
  Resource Metadata, April 2025; and
- [RFC 8414](https://www.rfc-editor.org/rfc/rfc8414), OAuth 2.0 Authorization
  Server Metadata, June 2018.

Current protocol truth resolves two points that older planning language can
misstate: RFC 9728 now requires the exact `resource` member, and the ATProto DID
specification selects the first matching PDS service rather than rejecting a
later duplicate as ambiguous.

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
zig build test-atproto-discovery
```

It covers the RFC 7636 PKCE vector, the public-key/thumbprint values published
in RFC 9449, P-256 JWK shape, query/fragment removal, access-token hashing,
nonce and input bounds, and verification of the emitted raw ES256 signature.
The gates compile both portable modules for `wasm32-freestanding` so an
accidental host dependency fails mechanically. The native std HTTP adapter is
tested only on the host target.

Discovery, SSRF/connection-address policy, metadata substitution, redirects,
response bounds, and changing-network-state tests are deterministic and
offline. Future host slices add loopback callback parsing, nonce rotation, session locking,
refresh crash recovery, diagnostic redaction, and mock end-to-end publication.
Automated tests must not require internet access. Live PDS compatibility is a
separate recorded manual gate using dedicated test identities.

## Explicitly not implemented

This is not a complete OAuth client. It does not resolve handles or DNS TXT,
open a browser, listen on loopback, issue PAR, display authorization UI,
exchange/refresh tokens, persist sessions or credentials, publish
Standard.site/XRPC records, prune remote state, authenticate CI, or implement
generic OAuth/DID provider support. No live-network smoke is in CI; a stable
non-personal public fixture was not identified, so this slice keeps all tests
offline rather than turning mutable public identity state into normative test
truth.
