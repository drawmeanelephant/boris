# AT Protocol persistent sessions contract

**Status:** normative host slice — durable DPoP-bound sessions, refresh with
rotate-or-die persistence, and explicit login/sessions/logout behavior are
implemented. This contract extends, never weakens, the identity and one-shot
authorization guarantees of [`atproto-oauth.md`](atproto-oauth.md).

This contract defines how Boris stores a user-authorized Standard.site session
across process restarts and refreshes it without repeating browser
authorization. It also fixes the failure model: every way a stored session can
go wrong — corruption, permission failure, revocation, expiry, scope loss, or
an authority change — is an explicit recovery state with a distinct exit
path, and no secret ever reaches a log, a diagnostic, evidence, or the
repository.

## Boundary and ownership

The portable OAuth core (`atproto_oauth`, `atproto_identity`,
`atproto_authorization`) remains free of filesystem, environment, process,
clock, and host key-store APIs, and still compiles under the
`wasm32-freestanding` gate. Session persistence is entirely host-side:

| Module | Role | Host-only? |
|---|---|---|
| `atproto_authorization` | `SessionWire` seam, `refresh` grant, `markObtained`, in-memory session | portable |
| `atproto_session_store` | user-scoped file store, wire format, lock, atomic replace, secure erase | host |
| `atproto_session_std` | root resolution, load/refresh/acquire, rotate-or-die, list/logout | host |

The wire format is the only serialization of a session. Tokens, the DPoP key
seed, and the Authorization Server nonce are `Token`/`ClientId`/bounded values
before and after serialization; they are hex- or string-encoded into the JSON
document and validated again on load, so a tampered or truncated document
fails closed as `StoreCorrupt` rather than deserializing a partial session.

## Storage

The store is user-scoped and least-permission:

- Default root: `$HOME/.local/share/boris/sessions`, or `--session-root PATH`.
  There is **no** silent fallback to a project file, repository directory,
  build output, or environment token.
- The root directory is created `0700`; each session document is `0600`.
- One JSON document per account, named `session-<hex(DID)>.json` (the DID is
  hex-encoded so the filename is filesystem-safe and non-reversible to a
  scanning process that only has the directory listing).
- A dedicated `lock` file carries an exclusive advisory lock. Every mutation
  (`save`, `load`-then-`refresh`, `remove`) is serialized behind it for the
  duration of the operation. The lock is released by the operating system if
  the holder dies, so a crashed process cannot wedge the store.
- Writes use an unnamed temporary file plus atomic rename, so a crash never
  leaves a half-written document. A replaced document is fully written and
  flushed before the rename commits.

The document is bounded to 64 KiB and is a `boris-session-v1` JSON object
holding exactly the material the current ATProto OAuth profile requires:
account DID, discovered authority identity (PDS origin, authorization-server
origin, authorization/token/PAR endpoints, optional verified handle), the
`client_id`, granted scope, access and optional refresh tokens, the DPoP key
seed, the Authorization Server nonce, and the access-token expiry and
obtained-at timestamps. No repository path, plan digest, or evidence binding
is stored.

### Secret discipline

Access token, refresh token, DPoP key seed, and the Authorization Server
nonce are the only secret fields. They are written only into the `0600`
document; the in-memory wire bytes and the read-back buffers are zeroed with
`secureZero` before free, and the session's `deinit` zeroes the key seed and
refresh token. `list` and the `sessions` command render DIDs only, never
tokens. Logs, diagnostics, evidence, and tests contain no live secret
material; tests use deterministic fixture strings that are not valid tokens.

## Refresh and rotation

`acquire(did, client, proofs, now)` is the single entry point used by
`standard-site publish`:

1. Load the stored document (returning `NoSession` when absent, so the publish
   provider falls back to the one-shot browser flow and persists the result).
2. If the access token is still comfortably valid — obtained-at plus
   `expires_in`, minus a five-minute early-refresh skew — return it without
   touching the network.
3. Otherwise run the DPoP refresh grant against the session's bound token
   endpoint, then persist the rotated session before returning it.

The refresh grant revalidates every binding before it can produce a session:
the `sub` DID must equal the bound account DID, the token type must be `DPoP`,
the granted scope must still contain both `atproto` and
`include:site.standard.authFull`, `expires_in` must be positive, and a fresh
`DPoP-Nonce` must arrive. Partial grants and identity changes fail instead of
producing a weakened session.

Refresh tokens are rotating, single-use credentials, and rotation is
**fail-closed**:

- A definitive rejection (`invalid_grant` → `SessionRevoked`, or a missing
  refresh token) removes the stale document and errors, so the operator
  re-authorizes cleanly.
- An ambiguous failure (timeout, transport error, malformed response) may
  mean the server already consumed the single-use token. The stale document is
  dropped and `RefreshAmbiguous` is returned rather than reusing a possibly
  consumed token on the next run.
- If a *successful* refresh cannot be persisted, the old document is removed
  anyway (`errdefer`) so the consumed single-use token is never left on disk
  to be burned again.

The early-refresh skew means a publish run never presents a token the PDS may
reject mid-flight; it also bounds the window in which two processes could
each try a refresh, and the exclusive lock serializes even that window.

## Recovery states and exit behavior

The publish command re-discovers the account identity on every run and
compares the stored session's DID, PDS origin, and authorization-server origin
against the fresh discovery result **before any mutation**. A stored session
bound to a different authority (`SessionAuthorityChanged`) fails closed with
zero network writes, even if its tokens are still cryptographically valid.

| State | Cause | Operator action |
|---|---|---|
| `NoSession` | nothing stored for the DID | publish falls back to the browser and persists; or `standard-site login` |
| `SessionRevoked` | server returned `invalid_grant` | `standard-site login --did <DID>` |
| `RefreshAmbiguous` | interrupted rotation, token may be consumed | `standard-site login --did <DID>` |
| `SessionAuthorityChanged` | DID moved PDS or authorization server | `standard-site login --did <DID>` |
| `StoreCorrupt` / `InvalidSessionWire` / `InvalidKeySeed` | tampered or truncated document | `standard-site logout --did <DID>`, then log in |
| `StorePermissionDenied` / `StoreLocked` / `StoreFull` / `StoreIo` | store not usable | fix permissions / wait for the lock / free space |
| `HomeUnavailable` | no `HOME` and no `--session-root` | pass `--session-root` or set `HOME` |

All of these map to exit code `9` (`session`) in
[`diagnostics.md`](diagnostics.md). `publish` can also return session exit 9
before any record write, so a stored-session failure never produces a partial
publication. `login`/`sessions`/`logout` report the same code on store errors.

## CLI surface

```text
boris standard-site login --did DID [--session-root PATH]
boris standard-site sessions [--session-root PATH]
boris standard-site logout --did DID [--session-root PATH]
```

- `login` resolves the DID, runs the interactive one-shot OAuth flow, and
  atomically persists the resulting DPoP-bound session. It never prints token
  material.
- `sessions` lists stored DIDs, one per line on stdout, in sorted order.
- `logout` securely erases the stored document. It does **not** revoke the
  authorization-server session: the refresh token remains usable server-side
  until it expires or the server revokes it (see limitations below).

`publish` uses the persistent store first: a stored, unexpired session is
loaded and reused without the browser; an expired one is refreshed in place;
and only when nothing is stored does it open the browser, then persist the new
session so the next publish skips authorization.

## Threat model and known limitations

The store protects against the threats it can honestly address, and documents
the rest:

- **Local disclosure.** The session document is `0600` inside a `0700`
  user-owned directory, and tokens never transit logs or command output.
  Boris does not integrate the OS keychain/Keyring/libsecret, so a process
  running as the same user (or a backup that captures the file) can read it.
  File permissions, not a hardware or keychain-backed secret store, are the
  trust boundary.
- **Secure erase is best-effort.** `logout` and rotation replacements zero the
  document bytes before unlink, but on copy-on-write filesystems, journaling
  filesystems, and SSDs the old blocks may remain recoverable at the device
  level. Boris cannot guarantee physical erasure; it guarantees the logical
  session path is gone and the refresh path is not reused.
- **Logout does not revoke server-side.** `logout` removes only the local
  copy. Revoking the authorization at the provider is out of scope (and not
  generally available through the public client profile), so a stolen local
  file remains a live refresh path until the token expires or the account
  revokes access out-of-band.
- **No cross-device or CI distribution.** The store is a single user's local
  directory. CI secret distribution and remote secret management are explicit
  non-goals.
- **Crash windows.** A crash between a successful refresh response and the
  atomic rename leaves the old document on disk; the fail-closed rotation rule
  treats the token as consumed and requires re-authorization rather than
  attempting to reuse it, which is the safe choice for a single-use token.
- **One account per DID.** The filename is the DID, so multiple DIDs coexist,
  but there is deliberately no multi-account identity selection beyond naming
  a DID explicitly.

## Test and acceptance surface

```text
zig build test-atproto-authorization
zig build test-atproto-session-store
zig build test-atproto-session-std
zig build test-standard-site-publish
```

These cover: survive-process-restart (save → load → publish reuses the
session), no-refresh when fresh, refresh-and-persist rotation, revoked-token
removal, ambiguous-timeout fail-closed, tampered-document fail-closed, lock
serialization across two open stores, list/save/replace/remove with no leaks,
`userRoot` override and `HOME` derivation, and the publish path's
stored-session-first / browser-fallback / authority-mismatch behavior. All
tests are offline with scripted discovery, OAuth, and PDS mocks; no live
network or real credential is involved.

## Explicitly not implemented

App passwords, silent migration of arbitrary credential formats, OS
keychain/keyring integration, server-side revocation on logout, CI secret
distribution, and any storage of credentials inside the repository, source
content, build output, publication plan, or evidence remain out of scope.
