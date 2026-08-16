# RFC: opt-in app-password authentication for Standard.site

**Status:** Implemented. `standard-site login --app-password` (with
`--did` or `--handle`), the `boris-app-password-v1` session document, and the
Bearer XRPC reuse in `publish`/`smoke` are live; the dependent contracts have
been amended accordingly (see
["Changes required on implementation"](#changes-required-on-implementation)).

**Scope:** a separate, explicit app-password credential path for the
`standard-site` family, in addition to — never instead of — the OAuth flow.

**Normative dependencies:**
[`atproto-oauth.md`](atproto-oauth.md),
[`atproto-sessions.md`](atproto-sessions.md),
[`standard-site.md`](standard-site.md),
[`atproto-live-smoke.md`](atproto-live-smoke.md).

## Decision summary

Adopt an explicit, opt-in app-password authentication path:

```text
boris standard-site login --app-password
```

The decision is:

1. OAuth stays the default and primary path. `login`, `publish`, and `smoke`
   keep their current OAuth behavior unchanged.
2. The app-password path is never a fallback. Nothing inside the OAuth flow
   ever downgrades to a credential; a failed scope check stays a fail-closed
   `InvalidTokenResponse` (exit 6) with zero writes.
3. The credential and its derived session are stored with the same
   least-permission discipline as OAuth sessions, and are redacted from logs,
   diagnostics, evidence, and the human summary.

## Why now

Two facts, both verified 2026-08-15, force this decision.

**The protocol endorses the path.** The AT Protocol's current guidance
explicitly carves out Boris's exact shape. [atproto.com/guides/auth][auth-guide]
states *"Single-purpose applications such as bots or command line tools may use
password authentication instead."* [atproto.com/guides/sdk-auth][sdk-auth]
states *"Password auth is acceptable for bots and command line tools"* and ships
a current, non-deprecated `PasswordSession.login` for that case. Password auth
is deprecated only for *user-facing* applications, not for the CLI-tool niche
Boris occupies. The original basis of the non-goal — "app passwords are
deprecated, therefore unsupported" — no longer holds.

**OAuth is unusable against the dominant PDS.** Boris requires the
`include:site.standard.authFull` permission set, but bsky.social's
authorization server grants only Bluesky's own permission sets, so a browser
authorization succeeds while the returned scope omits the Standard.site
permission, and Boris fails closed (`InvalidTokenResponse`, exit 6). This was
observed on 2026-08-15 with a dedicated bsky.social test identity. This is a
scope-grant gap,
not an infrastructure requirement: Boris's OAuth client is already a public
loopback client with no server-side component, so no hosted service is
involved on either path. The consequence is that the
whole publish → session → smoke chain is theoretical for the typical user: only
a self-hosted PDS that registers the Standard.site permission set can complete
an OAuth publish today.

App-password sessions carry full account write access with no per-lexicon scope
gate, which is why the Standard.site ecosystem (Sequoia and scripted
publishers) publishes `site.standard.*` records to bsky.social through
`createSession` today. An opt-in app-password path is therefore the only way to
make the live smoke completable against the PDS most users actually have.

[auth-guide]: https://atproto.com/guides/auth
[sdk-auth]: https://atproto.com/guides/sdk-auth

## Staging

This decision is the first rung of a ladder, not a replacement for OAuth:

1. **v1 (now).** Existing user PDS + app password + explicit CLI publish.
   Zero Boris-hosted infrastructure: no PDS, no Redis, no database, no
   callback server, nothing long-running.
2. **v1.x / v2.** A public/native OAuth client, if browser-consent login is
   wanted. Boris's current OAuth core already has this shape (public loopback
   client); the remaining work is static client metadata, not running a
   service. The `include:site.standard.authFull` permission set matters here.
3. **Future, only with a concrete product reason.** A confidential OAuth
   client or backend-for-frontend (BFF) infrastructure.
4. **Never a Boris requirement.** Operating a PDS.

The OAuth work already landed is not discarded: it remains the foundation for
rung 2 and the path that expresses Standard.site's least-privilege permission
model. This RFC only reorders which path ships first.

## The revised non-goal

The old stance bundled two claims; they are now judged separately.

- **Retired:** "app passwords are deprecated, so Boris must never accept one."
  Superseded by the protocol's CLI carve-out above.
- **Preserved, unchanged:** the security properties the non-goal actually
  protects. Boris must never *silently* fall back to a credential inside the
  OAuth flow, must never weaken the redirect/scope binding, must never export a
  token or credential, and must never print one. Those invariants survive this
  decision verbatim.

The net effect: the non-goal changes from "app passwords are unsupported" to
"app passwords are supported only as an explicit, separately-authorized,
non-fallback credential path, disclosed to the user at login."

## Design

**Entry point.** `standard-site login --app-password` is a sibling of the
OAuth `login`, never a flag on or fallback within the OAuth command. `publish`
and `smoke` reuse a stored app-password session exactly as they reuse a stored
OAuth session; neither command gains an inline password flag.

**Secret input.** The flag selects the mode; the password itself arrives via
stdin (prompted) or a dedicated secret file descriptor — never as a CLI
argument (which is visible in the process list), never an environment variable
holding the value, never the publication profile, never a log, never evidence,
never Git. This matches the existing Nostr secret discipline. On an
interactive terminal the echo is suppressed while typing (termios `ECHO` off
for the duration of the read, restored even on failure) and exactly one line
is consumed, so the credential never lands in terminal scrollback; on a pipe
or file the secret is read to end of stream. Either way the first newline
ends the credential and empty input is rejected.

**Authentication.** The command resolves the handle (or takes the DID
directly), calls `com.atproto.server.createSession` with the app password,
verifies the returned `did` matches the requested identity, and pins the PDS
origin — preserving the existing authority gate (`SessionAuthorityChanged` on
a fresh discovery mismatch, zero writes).

**Storage.** Reuse `atproto_session_store` wholesale: `0700` root, `0600`
document named `session-<hex(DID)>.json`, process-safe advisory lock, atomic
temp-file-plus-rename, secure-zero on removal, tamper-detection on load. The
document is a distinct `boris-app-password-v1` object holding only DID, PDS
origin, access token, optional refresh token, and expiry/obtained-at
timestamps — no DPoP key seed, no `client_id`, no scope, no nonce, so it can
never be mistaken for an OAuth session.

**Refresh.** `com.atproto.server.refreshSession` returns a single-use, rotating
`refreshJwt`. Reuse the sessions layer's rotate-or-die rule: a definitive
rejection and an ambiguous timeout both drop the stale document so a
single-use token is never replayed, and a successful-but-unpersistable rotation
also erases the stale copy.

**Redaction.** The credential and both JWTs flow through the same
`Token`-bounded, hex-encoded, non-printing discipline the OAuth tokens already
use; they never appear in diagnostics, evidence, the result artifact, or the
human summary.

**Revocation and disclosure.** `logout` removes only the local document;
server-side revocation stays a one-click user action in the provider's account
settings (same caveat as OAuth sessions). The `login --app-password` flow
states, before prompting: this grants broad account write access, not just the
Standard.site scope, and names the provider action that ends it.

## What is genuinely given up

Adding this path is not free; the RFC records the cost rather than hiding it.

- **Least privilege.** OAuth grants exactly `include:site.standard.authFull`.
  An app password grants broad account write. The scope check that today makes
  bsky.social "fail safely" does not exist on this path.
- **Client binding.** An OAuth token is DPoP-bound to Boris's key seed and only
  refreshes for Boris. A leaked app password or its `refreshJwt` is usable by
  *any* client against the account. The rotate-or-die rule protects against
  replay by Boris, not against theft of the credential itself.

These are accepted as a deliberate, per-account tradeoff the user opts into and
can end with a single revoke — a reasonable price for making the publish,
session, and smoke surface work against the PDS most people actually have.

## Changes required on implementation

All three dependent contracts were amended when the path landed:

- `atproto-oauth.md`: "Boris is OAuth-only and never accepts app passwords"
  and the "must not fall back to an app password" clause were replaced with the
  revised non-goal, and "app passwords" was moved out of the "Explicitly not
  implemented" list.
- `atproto-sessions.md`: the store now documents two document types
  (`boris-session-v1` and `boris-app-password-v1`) under one lock and one
  erase/replace discipline.
- `atproto-live-smoke.md`: the bsky.social limitation now states the smoke can
  complete against bsky.social via the opt-in app-password path, while the
  OAuth scope limitation itself remains accurate.

## Out of scope (unchanged)

CI secret distribution and remote secret management remain non-goals; the
credential is a single user's local, permission-locked document. No fallback
inside the OAuth flow, no token or credential export, and no weakening of the
redirect binding are introduced by this decision.
