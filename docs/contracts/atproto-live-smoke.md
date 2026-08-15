# AT Protocol live interoperability smoke contract

**Status:** normative manual gate — the opt-in live smoke command is implemented;
the live path is reachable only through an explicit CLI invocation and is never
part of `zig build test` or any default CI path.

This contract defines Boris's bounded, manual proof that discovery, OAuth, XRPC
writes, readback, verification surfaces, and cleanup behave against a real test
identity on a real PDS. It complements, never replaces, the deterministic
offline test matrix, which remains authoritative.

## Invocation

```text
boris standard-site smoke --did DID \
    [--namespace NAME] [--surface-url URL] [--indexer URL] \
    [--out PATH] [--session-root PATH]
```

`smoke` is the fifth member of the explicit `standard-site` family and is
never implicit. It requires `--did`; build/validate/watch/plan/init never
reach it, and no compiler-mode or projection flag is accepted.

## Test identity

The operator supplies a **dedicated, non-personal test identity**. Nothing
about a production account, publication, token, private key, or stable
credential is hard-coded; the DID and session root are operator inputs, and
the session is obtained exactly as publish obtains it (persistent store, then
interactive OAuth). The result records the DID, PDS, and authorization server
it exercised, but never any token, proof, nonce, or key material.

## Phases

`standard_site_smoke.smoke` orders the gate fail-closed:

1. **Discovery** — resolve the configured DID, then the PDS, Resource Server,
   and Authorization Server metadata (read-only, validated exactly as publish
   does).
2. **Authorization** — obtain a session (stored, refreshed, or a fresh
   interactive browser flow) and verify its DID, PDS, and authorization-server
   facts against the discovery result. A mismatch fails closed with zero
   writes.
3. **Namespace precondition** — derive a unique namespace (`--namespace`, or
   `boris-smoke-<epoch seconds>`), refuse to proceed if either target rkey
   already exists, and build a test publication + document pair:
   - `site.standard.publication` at `<namespace>-publication`;
   - `site.standard.document` at `<namespace>-document`, whose `site` field
     points at the publication AT-URI.
4. **Write** — `putRecord` both records; per-record failure is recorded and
   does not abort cleanup.
5. **Readback** — `getRecord` both records and verify the bound AT-URI, the
   record value against the intended payload (key-order-insensitive), and CID
   presence. Success is never claimed before this.
6. **Verification surface** — when `--surface-url` is given, fetch
   `https://<origin>/.well-known/site.standard.publication` and require a
   publication AT-URI body. Skipped when absent; a failure is recorded but is
   a smoke failure only when the check was requested.
7. **Indexer observation** — when `--indexer` is given, fetch the record via
   the indexer's `com.atproto.repo.getRecord`. Recorded as `observed`,
   `lagged`, or `failed`, and **never** part of the pass/fail decision.
8. **Cleanup** — delete exactly the two created rkeys. Cleanup is identity- and
   namespace-bound: it never enumerates, and it cannot prune records it did not
   create.

## Result

The result is a deterministic `boris-live-smoke-result` (schema v1) JSON
document written to `--out` or stdout. It contains: the overall verdict, the
run namespace, client pins (`boris`, `oliver`), the server identity facts
(DID, PDS, authorization server), the exact specification revisions tested
(the retrieval-dated baseline of
[`atproto-oauth.md`](atproto-oauth.md)), and one outcome object per phase with
per-record `status`, rkey, AT-URI, CID, and failure notes. It contains no
secret material. The human summary on stderr repeats only the verdict,
namespace, DID, and PDS.

## Exit behavior

`smoke` reuses the `standard-site` exit classification
([`diagnostics.md`](diagnostics.md)): `0` on a passing run, `2` usage, `3`
network/system, `4` denial, `5` timeout, `6` compatibility, `7` partial
(cleanup left a record, or a partial write), `8` verification (namespace
collision, readback or surface mismatch), `9` session. A nonzero exit still
writes the result artifact when the run reached the write phase, so the
operator can see exactly what landed and what was left behind.

## Interrupted-run recovery

If the process is interrupted after a write but before cleanup, the two
created records remain under the run's unique namespace. Recovery is manual
and bounded: re-run with the same `--namespace` is refused (namespace
collision, fail-closed), and the operator deletes only the two AT-URIs named
in the last result artifact. Nothing else is ever eligible.

## Exclusions and limitations

- The live path is not in `zig build test`, `scripts/release-gate.sh`, or any
  CI workflow; only the offline scripted-mock tests of the orchestration run
  in the ordinary matrix.
- Indexer observation is a non-normative signal; lag, absence, or failure is
  reported and never fails the run.
- One server implementation is never treated as normative protocol truth; the
  result records what was exercised, not a certification.
- The account's authorization server must grant `include:site.standard.authFull`
  (Standard.site's permission set). As of 2026-08-15, bsky.social's OAuth
  provider issues only Bluesky's own permission sets, so authorizing a
  bsky.social account succeeds in the browser but the returned scope omits the
  Standard.site permission; Boris fails closed with exit 6 (`compatibility`,
  `InvalidTokenResponse`) and zero writes. A live OAuth smoke therefore
  requires a PDS whose authorization server registers the Standard.site
  permission set (for example, a self-hosted PDS); app-password-based tooling
  is out of scope for Boris.
- No load testing, provider certification, or permanent demo account is in
  scope.

### PDS OAuth scope support

`include:site.standard.authFull` is a third-party permission set: the account's
authorization server must register it before it can grant it, and there is no
network-wide registry of who does. Findings as of 2026-08-15:

- **bsky.social — reads records, does not grant the scope.** Bluesky's AppView
ingests `site.standard.*` records and renders enhanced link cards
([atproto discussion #4978](https://github.com/bluesky-social/atproto/discussions/4978),
May 2026), but that is record *reading*; its OAuth provider issues only
Bluesky's own permission sets. A live smoke against a bsky.social account on
2026-08-15 authorized in the browser and failed the scope check with exit 6.
- **Leaflet — requests the scope via OAuth.** Leaflet's OAuth client requests
`include:site.standard.authFull` alongside Bluesky scopes (its February 2026
OAuth-scope commit), which confirms the scope spelling but means Standard.site
writes only succeed on a PDS whose authorization server grants it.
- **Sequoia and scripted publishers — app passwords, not OAuth.** The dominant
static-site tool (Sequoia) and hand-rolled publish scripts authenticate with
app passwords or `createSession`, which bypass OAuth scopes entirely. That is
why they work against bsky.social while Boris's OAuth flow does not.
- **No public provider is documented as granting the scope.** The Standard.site
implementation list documents clients and indexers, not PDS providers; the
Standard.site author's own OAuth deployment (andromeda.social) is self-hosted.

Net: a live OAuth smoke today requires a self-hosted PDS whose OAuth provider
registers the Standard.site permission set. bsky.social cannot complete one,
and Boris will not fall back to app passwords.

## Test surface

```text
zig build test-standard-site-smoke
```

The offline mock drives discovery, the one-shot PAR/callback/token exchange,
and a stateful PDS, covering: a full passing round-trip (write → readback →
cleanup with zero records left), deterministic and secret-free result
rendering, partial write with skipped readback and bounded cleanup, readback
value mismatch, cleanup failure leaving the record behind, optional surface
and non-gating indexer observation, and namespace-collision fail-closed with
zero writes.
